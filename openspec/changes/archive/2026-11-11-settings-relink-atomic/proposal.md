# Proposal

## Why

In a Claude Code session, `devenv shell` can delete `.claude/settings.json` (#68). When the link points at a different store path than the session's evaluation wants, #47's status check probes whether it can relink with `ln -sfn`. That removes the old link and then creates the new one. The sandbox lets the removal through and denies the create, so the probe itself deletes the link. After that there are no generated permissions, deny rules, sandbox config or guard hook on disk. Claude Code then keeps the path absent for the rest of the session. Any difference between a terminal's evaluation and the session's sets this off: a lock bump, a module change, or a terminal whose eval cache still holds an old module (seen in derekjw.com).

## What Changes

- The session relink probe becomes atomic. It creates the new link at a temporary name in the same directory, then renames it over the old one. If the sandbox denies any step, it removes the temporary link and reports the file stale, and the old link stays. At no point is a protected path missing.
- The probe moves from an inline string in `devenv.nix` into a small packaged script with its own test, which runs at build time, as `coldlogic-claude-guard`'s tests do.
- In a session, `devenv:files:cleanup` is also skipped when the recorded state lists a protected file under a spelling other than its current one (for example, relative instead of absolute). Cleanup would treat that entry as an orphan and remove the live link. This can't happen with the paths devenv 2.4 records today, so the guard is cheap insurance.
- `coldlogic:generated-files-stale` keeps its notice. Its advice adds `devenv shell --refresh-eval-cache`, for when a terminal shell leaves the files stale because its own evaluation is out of date.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `generated-files`: the session relink requirement now says a session never leaves a protected path missing, including when the sandbox allows the removal but denies the create. Two new requirements cover cleanup in a session: a respelled protected file, and state that can't be checked. The stale notice names `--refresh-eval-cache`.

## Impact

- `devenv.nix`: `sessionCannotRelink`, `tasks."devenv:files:cleanup".status`, and `coldlogic:generated-files-stale`.
- New `packages/session-relink.sh`, `packages/session-relink-test.sh` and `packages/session-relink.nix`.
- Every project on the module gets the fix on its next lock bump. A project whose session already deleted the link still needs one terminal `devenv shell` and a session restart to recover.
- Out of scope: Claude Code's own reverting of protected paths around tool calls (#68's comments), and devenv's `devenv:files` script, which still uses `ln -sf` outside a session.
