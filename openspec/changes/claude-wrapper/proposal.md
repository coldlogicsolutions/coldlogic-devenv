# Proposal

## Why

Claude Code reads `.claude/settings.json` when it starts. A session started while the generated link is missing or out of date runs without the guard hook, the sandbox settings or the permissions. #100 also caught, with `fs_usage` (`unlink … claude.<pid>`), a running session removing a settings link that was created after that session started: the root cause of #94. So the link has to be right before a session starts, and today the only way to get that is manual and order-sensitive: a terminal `devenv shell`, then a restart of every session before it runs another tool (#101).

## What Changes

- The developer shell puts a `claude` command on `PATH`, ahead of the real Claude Code. It refreshes the checkout's generated files, then starts the real `claude` with the same arguments, working directory, standard input and output.
- The refresh is `devenv --quiet tasks run devenv:files`, run at the top of the checkout the current directory is in. That runs devenv's cleanup, the session's own linking (a no-op here) and `devenv:files`: the file step of a terminal `devenv shell`, without the rest of the shell.
- Every invocation refreshes. The wrapper doesn't read its arguments.
- Inside a session (`CLAUDE_CODE_CHILD_SESSION` set, which Claude Code sets for its Bash, PowerShell and Monitor tools, hooks and status line) it refreshes nothing and starts the real `claude` at once. A session still never runs devenv's file tasks or writes the settings link.
- From an IDE extension's terminal, where `CLAUDECODE` is set but no session is running, it still refreshes: the wrapper clears `CLAUDECODE` for its own devenv run only. The file tasks keep their single `CLAUDECODE` test, unchanged.
- When the refresh fails, it says so on stderr. It then starts `claude` if the checkout's settings file is there, and refuses (exit 1) if it isn't, unless `COLDLOGIC_CLAUDE_START_ANYWAY` is set. The message names the override.
- It finds the real `claude` by skipping every `PATH` entry that is the wrapper itself or a wrapper that already ran in this launch, and exits 127 when there is none.
- README: a "What's here" row and the limits (only from the devenv shell or direnv; not the IDE extension's own launch or the desktop app; start `claude` in the checkout).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `generated-files`: the settings link is also refreshed by the `claude` wrapper before it starts a session, outside any session. New requirements cover the wrapper: when it refreshes, what it does when the refresh fails, how it passes the launch through, and how it finds the real `claude`. The Purpose says the wrapper refreshes outside a session.

## Impact

- New `packages/claude-wrapper.sh`, `packages/claude-wrapper-test.sh`, `packages/claude-wrapper.nix`. The build runs the tests, as for the other packages.
- `devenv.nix`: one `let` binding, one entry in the developer profile's `packages`, and one comment. No task changes.
- `scripts/check.sh`: one comment. `README.md`: one row and a short section.
- `openspec/specs/generated-files/spec.md`: the Purpose, edited directly (a delta can't carry it), and the delta on archive.
- Every `claude` started from the devenv shell now waits for one devenv evaluation first. The cost is unmeasured; a task measures it.
- Sessions need Claude Code 2.1.172 or later, the first version that sets `CLAUDE_CODE_CHILD_SESSION`.
- Overlap with the parallel `session-fresh-worktrees` change: both modify the `generated-files` requirement "A session never writes the settings link". See design.md.
- Out of scope: switching the file tasks or the prune task from `CLAUDECODE` to `CLAUDE_CODE_CHILD_SESSION`; changing the stale notice's text; refreshing for the IDE extension's own launch or the desktop app; OpenSpec's skills and the plugin install, which stay with `devenv shell`.
