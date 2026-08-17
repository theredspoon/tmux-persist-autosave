#!/usr/bin/env bash
#
# Blind-TDD regression test for persist-autosave.sh's $TMUX fallback.
#
# Spec under test (persist-autosave.sh around line 30-51): when launchd
# fires this script on its own timer, no tmux client is attached, so $TMUX
# is unset in that process's environment. Written and verified TDD-style:
# the fallback block was temporarily commented out, this suite was written
# against the spec below without looking at its logic, confirmed red, then
# the block was restored and confirmed green (see the PR description for
# the full red/green transcript).
# If the default tmux socket exists, the script should derive a fallback
# $TMUX pointing at it before doing anything else, WITHOUT ever touching an
# already-set $TMUX, and WITHOUT setting $TMUX at all when no default socket
# exists.
#
# Three cases:
#   A) $TMUX unset, default socket exists -> fallback fires, save is
#      well-formed (real tab-delimited layout, correct field counts, no
#      spurious regression-guard revert).
#   B) $TMUX already set -> left untouched (proven by absence of an
#      "export TMUX=" trace line, not just by the save happening to work).
#   C) $TMUX unset, no default socket -> stays unset, script exits 0
#      gracefully, no lock left behind.
#
# Out of scope (do not assert on these here): lock staleness/reclaim,
# .allow_regression bypass mechanics, general regression-guard pane-counting
# correctness beyond the one "0 reverted" check in case A.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers/test_helpers.sh"

REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PERSIST_AUTOSAVE="$REPO_DIR/persist-autosave.sh"
REAL_PLUGIN_DIR="$HOME/.tmux/plugins/tmux-persist"
REAL_SAVE_SCRIPT="$REAL_PLUGIN_DIR/scripts/save.sh"

if [ ! -x "$REAL_SAVE_SCRIPT" ]; then
	echo "test_tmux_env_fallback: tmux-persist not found at $REAL_PLUGIN_DIR (need scripts/save.sh)" >&2
	exit 1
fi

# Real, empirically-verified field counts for a "pane"/"window" line as
# actually written to a snapshot's ./layout by tmux-persist's save.sh
# (scripts/save.sh: dump_panes()/dump_windows()), NOT the raw field count of
# pane_format()/window_format() used for the intermediate `tmux list-panes`/
# `list-windows` dump. dump_panes() reads 12 raw fields via pane_format() but
# only re-emits 11 of them (pane_pid and history_size are consumed, not
# written); dump_windows() reads 7 raw fields via window_format() but emits 8
# (an extra automatic_rename field is appended). Confirmed both by reading
# scripts/save.sh/variables.sh and by an actual save.sh run against a real
# 2-window/3-pane session, dumping ./layout and counting tabs directly.
PANE_FIELDS=11
WINDOW_FIELDS=8

# --- shared plumbing -------------------------------------------------------

# Builds an isolated tmux server at -L default inside $1 (a TMUX_TMPDIR),
# with session "work": window 0 (1 pane) + window 1 (split into 2 panes) =
# 2 windows / 3 panes of real structure. Then points its @persist-dir at $2.
build_session() { # iso_tmpdir persist_dir
	local iso="$1" pdir="$2"
	TMUX_TMPDIR="$iso" tmux -L default -f /dev/null new-session -d -s work
	TMUX_TMPDIR="$iso" tmux -L default new-window -t work
	TMUX_TMPDIR="$iso" tmux -L default split-window -t work:1
	TMUX_TMPDIR="$iso" tmux -L default set -g @persist-dir "$pdir"
}

# Seeds a real "prior" work_last snapshot by calling tmux-persist's own
# save.sh through `tmux run-shell` (so $TMUX is set the normal way, by tmux
# itself - nothing to do with the fallback under test). This gives the
# following persist-autosave.sh run a prior snapshot with >=2 panes, which is
# what makes this suite's "0 reverted" check in case A/B an observable signal
# tied to the fix rather than trivially true (a first-ever save has no prior
# snapshot at all, so the regression guard could never fire either way).
seed_prior_snapshot() { # iso_tmpdir persist_dir
	local iso="$1" pdir="$2"
	TMUX_TMPDIR="$iso" tmux -L default run-shell "'$REAL_SAVE_SCRIPT' quiet work"
	sleep 0.6
	if [ ! -L "$pdir/work_last" ]; then
		echo "test_tmux_env_fallback: fixture setup failed - seeding the prior work_last snapshot did not produce a symlink in $pdir" >&2
		exit 1
	fi
}

# Resolves a persist-dir "_last" symlink to its snapshot file's absolute path.
resolve_last_target() { # persist_dir
	local pdir="$1" link
	link="$(readlink "$pdir/work_last" 2>/dev/null)" || return 1
	case "$link" in
		/*) printf '%s\n' "$link" ;;
		*) printf '%s\n' "$pdir/$link" ;;
	esac
}

# The snapshot persist-autosave.sh's own save.sh call JUST wrote, regardless
# of whether the regression guard then reverted work_last back to the prior
# snapshot. Can't just look for "a work_*.txt file that wasn't there
# before": tmux-persist's save.sh skips writing a new file at all when the
# content is unchanged from the latest snapshot (it just refreshes that
# same file's mtime instead - see README's "@persist-skip-unchanged"), which
# is exactly what happens here since the seeded prior snapshot and this
# run's save are identical session content. So:
#   - no revert -> work_last already correctly points at whatever save.sh
#     did (new file or unchanged-refresh alike), resolve_last_target is right.
#   - revert -> work_last was pointed BACK at the prior snapshot, but
#     persist-autosave.sh's own log line names the degenerate file it left
#     on disk ("degenerate snapshot <name> kept on disk for forensics") -
#     parse that filename out of $3 (the run's stdout) instead of trusting
#     the symlink, which would otherwise read the stale-but-good prior data.
resolve_new_snapshot() { # persist_dir pre_run_target stdout
	local pdir="$1" out="$3" name
	name="$(printf '%s\n' "$out" | sed -n 's/.*degenerate snapshot \([^ ]*\) kept on disk.*/\1/p' | tail -1)"
	if [ -n "$name" ]; then
		case "$name" in
			/*) printf '%s\n' "$name" ;;
			*) printf '%s\n' "$pdir/$name" ;;
		esac
		return 0
	fi
	resolve_last_target "$pdir"
}

# Asserts a ./layout blob has exactly the pane/window structure this suite's
# sessions always create (3 panes, 2 windows), with every line intact at the
# real field count - i.e. NOT collapsed to 1 field, which is what the bug
# this fix addresses does (every tab delimiter replaced with "_").
assert_layout_well_formed() { # layout_content label
	local layout="$1" label="$2"
	local pane_lines window_lines bad_pane_fields bad_window_fields

	pane_lines="$(printf '%s\n' "$layout" | grep -c $'^pane\t')"
	assert_eq "$pane_lines" "3" "$label: pane-line count matches the 3 panes created"

	window_lines="$(printf '%s\n' "$layout" | grep -c $'^window\t')"
	assert_eq "$window_lines" "2" "$label: window-line count matches the 2 windows created"

	bad_pane_fields="$(printf '%s\n' "$layout" | awk -F'\t' -v want="$PANE_FIELDS" '$1=="pane" && NF!=want {c++} END{print c+0}')"
	assert_eq "$bad_pane_fields" "0" "$label: every pane line has $PANE_FIELDS tab-separated fields (not collapsed to 1)"

	bad_window_fields="$(printf '%s\n' "$layout" | awk -F'\t' -v want="$WINDOW_FIELDS" '$1=="window" && NF!=want {c++} END{print c+0}')"
	assert_eq "$bad_window_fields" "0" "$label: every window line has $WINDOW_FIELDS tab-separated fields (not collapsed to 1)"
}

cleanup_case() { # iso_tmpdir
	local iso="$1"
	TMUX_TMPDIR="$iso" tmux -L default kill-server 2>/dev/null
	rm -rf "$iso" "${CASE_PDIR:-}" "${CASE_TMPDIR:-}" "${CASE_WORKDIR:-}"
}

# --- Case A: $TMUX unset, default socket exists -> fallback fires ----------

echo "case A: TMUX unset, default socket exists"
{
	CASE_ISO="$(mktemp -d "${TMPDIR:-/tmp}/tpa-test.XXXXXX")"
	CASE_PDIR="$(mktemp -d "${TMPDIR:-/tmp}/tpa-test.XXXXXX")"
	CASE_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/tpa-test.XXXXXX")"
	CASE_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/tpa-test.XXXXXX")"

	build_session "$CASE_ISO" "$CASE_PDIR"
	seed_prior_snapshot "$CASE_ISO" "$CASE_PDIR"
	PRE_TARGET="$(resolve_last_target "$CASE_PDIR")"

	# env -i, not just "env -u TMUX": launchd's actual environment has no
	# LANG/LC_ALL/LC_CTYPE/TERM either, and that turns out to be what
	# actually triggers tmux's -F format engine mangling tabs into "_" - a
	# genuinely $TMUX-unset-but-otherwise-normal-interactive-shell (LANG
	# still set) does NOT reproduce the bug at all, verified directly. PATH
	# is deliberately minimal (no Homebrew), matching launchd's default, so
	# this also exercises persist-autosave.sh's own PATH export.
	env -i HOME="$HOME" PATH="/usr/bin:/bin" \
		TMUX_TMPDIR="$CASE_ISO" \
		TMPDIR="$CASE_TMPDIR" \
		TMUX_PERSIST_PLUGIN_DIR="$REAL_PLUGIN_DIR" \
		bash -x "$PERSIST_AUTOSAVE" \
		>"$CASE_WORKDIR/stdout.log" 2>"$CASE_WORKDIR/stderr.log"
	CASE_EXIT=$?

	TRACE="$(cat "$CASE_WORKDIR/stderr.log")"
	OUT="$(cat "$CASE_WORKDIR/stdout.log")"

	assert_contains "$TRACE" "export TMUX=" "case A: trace shows the fallback branch exporting TMUX"
	assert_eq "$CASE_EXIT" "0" "case A: exits 0"
	assert_file "$CASE_PDIR/work_last" "case A: work_last symlink exists"

	# Deliberately NOT resolve_last_target here: if the regression guard
	# reverts, work_last points at the stale-but-good PRIOR snapshot, which
	# would make these assertions pass vacuously on data this run never
	# wrote. resolve_new_snapshot finds the actual save this run produced.
	if TARGET="$(resolve_new_snapshot "$CASE_PDIR" "$PRE_TARGET" "$OUT")" && [ -f "$TARGET" ]; then
		LAYOUT="$(tar xzOf "$TARGET" ./layout 2>/dev/null)"
		assert_layout_well_formed "$LAYOUT" "case A"
	else
		_ko "case A: pane-line count matches the 3 panes created (no new snapshot written)"
		_ko "case A: window-line count matches the 2 windows created (no new snapshot written)"
		_ko "case A: every pane line has $PANE_FIELDS tab-separated fields (not collapsed to 1) (no new snapshot written)"
		_ko "case A: every window line has $WINDOW_FIELDS tab-separated fields (not collapsed to 1) (no new snapshot written)"
	fi

	assert_contains "$OUT" "0 reverted" "case A: summary line shows 0 reverted"

	cleanup_case "$CASE_ISO"
}

# --- Case B: $TMUX already set -> left untouched ----------------------------

echo "case B: TMUX already set, must not be overwritten"
{
	CASE_ISO="$(mktemp -d "${TMPDIR:-/tmp}/tpa-test.XXXXXX")"
	CASE_PDIR="$(mktemp -d "${TMPDIR:-/tmp}/tpa-test.XXXXXX")"
	CASE_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/tpa-test.XXXXXX")"
	CASE_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/tpa-test.XXXXXX")"

	build_session "$CASE_ISO" "$CASE_PDIR"
	seed_prior_snapshot "$CASE_ISO" "$CASE_PDIR"
	PRE_TARGET="$(resolve_last_target "$CASE_PDIR")"

	SOCKET="$CASE_ISO/tmux-$(id -u)/default"
	PRESET_TMUX="$SOCKET,9999,9999"

	# Same stripped launchd-like env as case A (see its comment) - the point
	# of this case is that a pre-set $TMUX alone is enough even under those
	# conditions, and the fallback must not clobber it.
	env -i HOME="$HOME" PATH="/usr/bin:/bin" TMUX="$PRESET_TMUX" \
		TMUX_TMPDIR="$CASE_ISO" \
		TMPDIR="$CASE_TMPDIR" \
		TMUX_PERSIST_PLUGIN_DIR="$REAL_PLUGIN_DIR" \
		bash -x "$PERSIST_AUTOSAVE" \
		>"$CASE_WORKDIR/stdout.log" 2>"$CASE_WORKDIR/stderr.log"
	CASE_EXIT=$?

	TRACE="$(cat "$CASE_WORKDIR/stderr.log")"
	OUT="$(cat "$CASE_WORKDIR/stdout.log")"

	assert_not_contains "$TRACE" "export TMUX=" "case B: trace shows TMUX was never (re)exported"
	assert_eq "$CASE_EXIT" "0" "case B: exits 0"
	assert_file "$CASE_PDIR/work_last" "case B: work_last symlink exists"

	if TARGET="$(resolve_new_snapshot "$CASE_PDIR" "$PRE_TARGET" "$OUT")" && [ -f "$TARGET" ]; then
		LAYOUT="$(tar xzOf "$TARGET" ./layout 2>/dev/null)"
		assert_layout_well_formed "$LAYOUT" "case B"
	else
		_ko "case B: pane-line count matches the 3 panes created (no new snapshot written)"
		_ko "case B: window-line count matches the 2 windows created (no new snapshot written)"
		_ko "case B: every pane line has $PANE_FIELDS tab-separated fields (not collapsed to 1) (no new snapshot written)"
		_ko "case B: every window line has $WINDOW_FIELDS tab-separated fields (not collapsed to 1) (no new snapshot written)"
	fi

	assert_contains "$OUT" "0 reverted" "case B: summary line shows 0 reverted"

	cleanup_case "$CASE_ISO"
}

# --- Case C: $TMUX unset, no default socket -> stays unset, graceful exit --

echo "case C: TMUX unset, no tmux server at the default socket"
{
	CASE_ISO="$(mktemp -d "${TMPDIR:-/tmp}/tpa-test.XXXXXX")"
	CASE_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/tpa-test.XXXXXX")"
	CASE_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/tpa-test.XXXXXX")"
	CASE_PDIR=""
	# No build_session call: this is a fresh, empty TMUX_TMPDIR with no
	# server ever started at -L default.

	env -u TMUX \
		TMUX_TMPDIR="$CASE_ISO" \
		TMPDIR="$CASE_TMPDIR" \
		TMUX_PERSIST_PLUGIN_DIR="$REAL_PLUGIN_DIR" \
		bash -x "$PERSIST_AUTOSAVE" \
		>"$CASE_WORKDIR/stdout.log" 2>"$CASE_WORKDIR/stderr.log"
	CASE_EXIT=$?

	TRACE="$(cat "$CASE_WORKDIR/stderr.log")"
	OUT="$(cat "$CASE_WORKDIR/stdout.log")"

	assert_eq "$CASE_EXIT" "0" "case C: exits 0"
	assert_contains "$OUT" "skipped (no tmux server running)" "case C: stdout reports the graceful skip"
	assert_not_contains "$TRACE" "export TMUX=" "case C: trace shows TMUX was never exported"
	assert_no_file "$CASE_TMPDIR/tmux-persist-autosave.lock" "case C: no lock directory left behind"

	cleanup_case "$CASE_ISO"
}

finish
