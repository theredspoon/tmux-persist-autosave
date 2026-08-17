#!/usr/bin/env bash
#
# Minimal self-contained test helpers, adapted from tmux-persist's own
# tests/helpers/test_helpers.sh (~/.tmux/plugins/tmux-persist/tests/helpers/test_helpers.sh):
# same _ok/_ko/assert_*/finish API, no external test framework, no
# dependencies beyond bash.
#
# Each test file sources this, makes assertions via the assert_* functions,
# then calls `finish` (whose exit status reflects pass/fail).

TESTS_PASSED=0
TESTS_FAILED=0

# assertions
_ok() { TESTS_PASSED=$((TESTS_PASSED + 1)); printf '  ok   - %s\n' "$1"; }
_ko() { TESTS_FAILED=$((TESTS_FAILED + 1)); printf '  FAIL - %s\n' "$1"; }

assert_contains()     { case "$1" in *"$2"*) _ok "$3";; *) _ko "$3 (missing: $2)";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _ko "$3 (unexpected: $2)";; *) _ok "$3";; esac; }
assert_file()          { [ -e "$1" ] && _ok "$2" || _ko "$2 (no file: $1)"; }
assert_no_file()       { [ ! -e "$1" ] && _ok "$2" || _ko "$2 (exists: $1)"; }
assert_eq()             { [ "$1" = "$2" ] && _ok "$3" || _ko "$3 (got '$1', want '$2')"; }

finish() {
	echo "  -> ${TESTS_PASSED} passed, ${TESTS_FAILED} failed"
	[ "$TESTS_FAILED" -eq 0 ]
}
