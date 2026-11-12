# Proposal

## Why

`coldlogic-prune-worktrees` runs from the SessionStart and Stop hooks, outside the Bash sandbox (#82, from the security review of #81). It writes its files in the git common dir, which a sandboxed session can write too. It appended to `.git/coldlogic-prune.log` (`say()` and the detached run's `nohup … >>"$log"`) and touched `.git/coldlogic-prune.stamp` without checking for a link, wrote its state through predictable `.tmp.$$` names, and put branch names and paths into log lines unquoted. A session that plants `.git/coldlogic-prune.log` as a link to `~/.zshrc` would have the next hook run append to it, and a branch named with `$(…)` would make the appended line shell code. Planting the link is a deliberate act, so this is a follow-up, not a blocker.

## What Changes

- The log is written only when it is absent (then made with noclobber, mode 600) or a regular file of the user's, not a link, with one name. Otherwise the run removes nothing (a removal without its restore record isn't allowed), prints one line to stderr and exits 0; a dry run is unaffected. The detached run's output goes to the same checked log, and a `--background` run with an unusable log doesn't detach.
- The kept file is read only under the same conditions, so a link can't copy a file the sandbox can't read into one it can.
- Every rewritten file (the kept file, a trimmed log) is written to a `mktemp` file beside it and renamed into place. The lock's owner file is made with noclobber, and the stamp is replaced by a new empty file (a `mktemp` file renamed over it), which never follows a link or touches a hard link's other name.
- Every branch name and path in a log line is shell-quoted with `printf %q`, as the restore commands already were; a git error or lock owner is free text, cleaned (`clean`: control characters to spaces, `$(` and backquotes defused) so it stays readable.
- Each removal's "removing ...; to restore: ..." line is written before the removal; when it can't be, the removal is skipped for the next run.
- Read-only finding on the sandbox (task 3): Claude Code itself denies writes to `.git/hooks` and `.git/config` under the session's launch directory, but not to `.git/coldlogic-prune.*` or to `.git/worktrees/<name>/config.worktree`. The last is a wider version of the same escape; it is reported, not fixed here.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `worktree-cleanup`: "Removals are logged for good" now says every name and path in a log line is quoted. A new requirement says the command never writes through a link or into a file that isn't a regular one of the user's with one name.

## Impact

- `packages/prune-worktrees.sh` and `packages/prune-worktrees-test.sh`.
- Log lines naming a branch or path with shell characters read differently (`feat\]x`, `a\ b`); git errors and lock owners are cleaned, not quoted. A kept reason whose text changes is logged once more on the first run after the update. A removal is now preceded by a "removing ..." line.
- Out of scope: the common dir itself being a link (it is what `git rev-parse --git-common-dir` returns, and every name the run writes there is its own `coldlogic-prune.*`); git configuration a session can write (`config.worktree`), reported in design.md.
