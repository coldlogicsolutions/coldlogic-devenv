# Design

## Context

devenv 2.4 puts its runtime dir at `${XDG_RUNTIME_DIR:-/tmp}/devenv-<hash of the checkout>`. It creates the dir, and any missing parents, before it evaluates `devenv.nix`, so nothing in the shell itself can move it. Only the environment that launches `devenv` can. `claude.code.env` becomes the `env` block of the generated settings, and Claude Code passes that block to every Bash command a session runs. The sandbox already allows writes to `~/.cache/devenv`. See proposal.md for the failure this fixes.

## Goals / Non-Goals

**Goals:** a session's `devenv shell` works in any checkout or worktree without `/tmp` access.

**Non-Goals:** changing where a terminal's devenv puts its runtime dir; the `config.worktree` write that `coldlogic:worktree-hooks-path` makes (ticketed separately).

## Decisions

1. **A static `XDG_RUNTIME_DIR` in `claude.code.env`, `${HOME}/.cache/devenv/run`.** `HOME` is read with `builtins.getEnv`, as `gnupgHome` already does. It is checked against the sandbox: `XDG_RUNTIME_DIR=~/.cache/devenv/run devenv shell` in an agent worktree created `~/.cache/devenv/run/devenv-1c62013` and entered the shell.
   *Alternatives:* (a) `XDG_RUNTIME_DIR=$TMPDIR` as a command prefix. This was rejected in agent-worktrees: `$TMPDIR` is per session, and the prefix defeats the guard's wrapper unwrapping. A static settings value avoids both. (b) The `/tmp/devenv-*` globs. Shown not to work in #64: the sandbox drops them. (c) A literal `/private/tmp` allow. Too broad.
2. **Under `~/.cache/devenv`, not `~/.local/share/devenv`.** Runtime dirs are disposable, and that is what a cache is for. The path also stays short. The longest socket path devenv makes there is about 70 bytes for this user, well under macOS's 104-byte `sun_path` limit.
3. **Remove the four `/tmp/devenv-*` entries.** They are dropped anyway. Keeping them would suggest access the sandbox doesn't give, and they reach every project's runtime dir.

## Risks / Trade-offs

- **[Split runtime dirs]** A terminal's shell keeps `/tmp/devenv-<hash>`, so `devenv up` processes started from a terminal aren't found by a session, and the other way round. → No current project relies on a session talking to a terminal's `devenv up`. If one does, its developer can set the same `XDG_RUNTIME_DIR` in their shell profile.
- **[Other XDG readers]** Every command in a session sees the new `XDG_RUNTIME_DIR`. On macOS nothing else in the shared toolset reads it. On Linux, tools that expect the systemd user runtime dir (D-Bus, Wayland sockets) would look in the wrong place. → Sessions run headless tools only. Revisit if a Linux user hits it.
- **[Stale dirs]** Runtime dirs build up under `~/.cache/devenv/run`, one per worktree. → They are small, and cache cleaners may delete them. devenv recreates one when it's missing.
