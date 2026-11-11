# Proposal

## Why

A subagent in a fresh worktree can't enter `devenv shell` during a Claude Code session. devenv creates its runtime dir at `/tmp/devenv-<hash of the checkout>`, and the sandbox drops the `/tmp/devenv-*` glob entries from `allowWrite` entirely (all four forms, verified in #64). So the first shell fails with `Failed to create /tmp/devenv-<hash>: Operation not permitted`.

## What Changes

- The generated Claude Code settings set `XDG_RUNTIME_DIR` to `<home>/.cache/devenv/run` in `env`. devenv puts its runtime dirs under `$XDG_RUNTIME_DIR`, and the sandbox already lets sessions write `~/.cache/devenv`.
- The four `/tmp/devenv-*` entries are removed from `sandbox.filesystem.allowWrite`. They didn't work, and they reached every project's runtime dir in `/tmp`. Sessions' runtime dirs now share `~/.cache/devenv/run`, which the existing `~/.cache/devenv` allow already covers. That gives no isolation between projects' session runtime dirs, the same as before.
- README's `devenv.nix` row and the session-permissions spec describe the new location and drop the "pending verification in #64" notes.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `session-permissions`: the sandbox requirement stops naming `/tmp/devenv-*`. A new requirement says sessions keep devenv's runtime dirs under the devenv cache.

## Impact

- `devenv.nix`: `claude.code.env` and `sandbox.filesystem.allowWrite`.
- Every project that uses the module gets the new env var once it regenerates its settings.
- `devenv up` processes started from a terminal use `/tmp/devenv-<hash>`, so a session won't see them (design.md, Risks).
- Out of scope: the sandbox also blocks a fresh worktree's first shell from writing `.git/worktrees/<name>/config.worktree` (`coldlogic:worktree-hooks-path`). That is ticketed separately.
