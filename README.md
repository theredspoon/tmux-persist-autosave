# tmux-persist-autosave

A macOS `launchd` job that periodically saves every live tmux session via
[tmux-persist](https://github.com/hyoretsu/tmux-persist), independent of any
attached tmux client.

## Why

tmux-persist auto-saves on clean detach/exit, which covers most cases. It
doesn't cover a hard crash while you're still attached — no clean detach
means the save-on-exit hook never fires. `tmux-continuum` (the periodic-save
companion for the original tmux-resurrect) doesn't solve this either: its
timer is implemented as a shell command embedded in tmux's status-line format
string, so it only fires while a client is actively rendering the status bar,
and can silently stop working if `status-right` is off or overwritten by a
theme/plugin ([known](https://github.com/tmux-plugins/tmux-continuum/issues/42)
[issues](https://github.com/tmux-plugins/tmux-continuum/issues/54)).

This does the same job with a genuine OS-level timer instead, via
`launchd`'s `StartInterval`. It runs whether or not anything is attached.

## What it does

- Every 10 minutes (configurable), saves every live tmux session by calling
  tmux-persist's own `scripts/save.sh quiet <session>` per session.
- **Regression guard**, adapted from
  [omriariav/tmux-resurrect-launchd](https://github.com/omriariav/tmux-resurrect-launchd)
  (built for the original tmux-resurrect; reimplemented here for
  tmux-persist's per-session snapshot model): if a session's snapshot
  suddenly has far fewer panes than its previous one, the save is reverted
  rather than accepted — protects against a session that crashed down to a
  bare single pane silently clobbering a richer saved state on the next
  tick. Deliberately reduced a session on purpose and want that saved
  anyway? `touch <persist-dir>/<session>_last.allow_regression` before the
  next tick to bypass the guard once.
- Resolves the same directory tmux-persist itself would use (respects
  `@persist-dir`, falls back to the legacy `@resurrect-dir`, then its own
  default) by sourcing tmux-persist's own helpers rather than guessing.
- Single-flight locking (a plain `mkdir`-based lock, no dependency on
  `flock` being installed) so overlapping ticks, or a tick racing a manual
  `prefix + Ctrl-s`, can't corrupt a snapshot mid-write.

## Install

Requires [tmux-persist](https://github.com/hyoretsu/tmux-persist) already
installed (e.g. via [TPM](https://github.com/tmux-plugins/tpm)) at
`~/.tmux/plugins/tmux-persist`. If it's installed elsewhere, set
`TMUX_PERSIST_PLUGIN_DIR` before running the script (see `persist-autosave.sh`).

```sh
git clone https://github.com/theredspoon/tmux-persist-autosave
cd tmux-persist-autosave
./install.sh
```

This copies `persist-autosave.sh` to `~/.local/bin/`, installs a LaunchAgent
plist to `~/Library/LaunchAgents/`, and loads it immediately.

macOS will show this as a new background item (System Settings > General >
Login Items & Extensions), labeled "unidentified developer" — expected,
since it's a plain shell script, not a code-signed binary.

To remove: `./uninstall.sh`.

## Logs

`~/Library/Logs/tmux-persist-autosave.log`

## Platform

macOS only (`launchd`). On Linux, `persist-autosave.sh` itself is portable
bash — wire it into a `systemd --user` timer instead of the plist/install.sh
here.

## A caveat worth knowing

`persist-autosave.sh` sources tmux-persist's internal `scripts/helpers.sh`
and `scripts/variables.sh` directly and calls its internal `persist_dir()`
and `_sanitize_session_for_path()` functions. None of that is a documented,
stable public API — it's how this script stays in sync with tmux-persist's
own directory-resolution and filename-encoding logic rather than
reimplementing (and risking drifting from) it, but it does mean an upstream
refactor could rename or remove either function without notice. The script
checks both exist right after sourcing and aborts with an explicit message
if not, so a shape change fails loudly and immediately rather than silently
doing the wrong thing — but it still means this script needs updating
whenever that happens. If tmux-persist ever exposes a stable API for this,
this script should move to it.

## Credits

- [tmux-persist](https://github.com/hyoretsu/tmux-persist) — the plugin
  this wraps.
- [omriariav/tmux-resurrect-launchd](https://github.com/omriariav/tmux-resurrect-launchd) —
  source of the regression-guard idea, reimplemented here for tmux-persist's
  different (per-session) snapshot model.

## License

MIT, see [LICENSE](LICENSE).
