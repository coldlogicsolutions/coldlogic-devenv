# Proposal

## Why

Claude Code reads `.claude/settings.json` when it starts. A session started while the generated link is missing or out of date runs without the guard hook, the sandbox settings or the permissions. #100 also caught, with `fs_usage` (`unlink … claude.<pid>`), a running session removing a settings link that was created after that session started: the root cause of #94. So the link has to be right before a session starts, and today the only way to get that is manual and order-sensitive: a terminal `devenv shell`, then a restart of every session before it runs another tool (#101).

The shell also decides "am I in a session?" by testing Claude Code's `CLAUDECODE` in five places. That variable is set in IDE terminals too, where no session runs, and a test named for someone else's variable is hard to read.

## What Changes

- The developer shell puts a `claude` command on `PATH`, ahead of the real Claude Code. It refreshes the checkout's generated files, then starts the real `claude` with the same arguments, working directory, standard input and output.
- The refresh is `devenv --quiet tasks run devenv:files`, run at the top of the checkout the current directory is in. That runs devenv's cleanup, the session's own linking (a no-op here) and `devenv:files`: the file step of a terminal `devenv shell`, without the rest of the shell.
- Every invocation refreshes. The wrapper doesn't read its arguments. A refresh that works prints nothing, and is trusted: `claude` starts whatever state the settings link is in.
- The wrapper marks the session it starts: it sets `COLDLOGIC_DEVENV_SESSION=1` for Claude Code, so every tool call, hook and server of that session inherits it.
- **The shell's session test changes.** It becomes one definition in `devenv.nix`, used by all five places: the module's marker is set, or `CLAUDECODE` is. `CLAUDECODE` stays only as the fallback for sessions the wrapper didn't start (the desktop app, the IDE extension's own launch), so #68's protection holds there.
- The wrapper refreshes nothing when the marker is set, or `CLAUDE_CODE_CHILD_SESSION` is (the fallback for a `claude` run inside a session the wrapper didn't start). It then starts the real `claude` at once.
- From an IDE extension's terminal, where `CLAUDECODE` is set but no session runs, the wrapper still refreshes: it clears `CLAUDECODE` and the marker for its own devenv run only.
- When the refresh fails, it says so on stderr. It then starts `claude` if the checkout's settings file is there, and refuses (exit 1) if it isn't, unless `COLDLOGIC_START_WITHOUT_SETTINGS` is set. The message names the override.
- It finds the real `claude` by skipping every `PATH` entry that is the wrapper itself or a wrapper that already ran in this launch, and exits 127 when there is none.
- README: a "What's here" row and the limits (only from the devenv shell or direnv; not the IDE extension's own launch or the desktop app; start `claude` in the checkout).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `generated-files`: one shared session test (the module's marker, or `CLAUDECODE`) replaces the `CLAUDECODE` test in the requirements that name it. The settings link is also refreshed by the `claude` wrapper before it starts a session. New requirements cover the wrapper: when it refreshes, the marker it sets, what it does when the refresh fails, how it passes the launch through, and how it finds the real `claude`. The Purpose says the wrapper refreshes outside a session.
- `worktree-cleanup`: the terminal shell's prune uses the shared session test, not `CLAUDECODE` alone.

## Impact

- New `packages/claude-wrapper.sh`, `packages/claude-wrapper-test.sh`, `packages/claude-wrapper.nix`. The build runs the tests, as for the other packages.
- `devenv.nix`: one `let` binding and one `packages` entry for the wrapper; one shared session test, used by the two file-task statuses, `coldlogic:session-files`, `coldlogic:generated-files-stale` and `coldlogic:prune-worktrees` (one line each); comments.
- `scripts/check.sh`: one comment. `README.md`: one row and a short section.
- `openspec/specs/generated-files/spec.md`: the Purpose, edited directly (a delta can't carry it), and the deltas on archive.
- Every `claude` started from the devenv shell now waits for one devenv evaluation first. The cost is unmeasured; a task measures it.
- A `claude` run inside a session the wrapper didn't start relies on Claude Code 2.1.172 or later, the first version that sets `CLAUDE_CODE_CHILD_SESSION`.
- Overlap with the parallel `session-fresh-worktrees` change: both edit `coldlogic:generated-files-stale` and one `generated-files` requirement, and that change's new shell logic tests `CLAUDECODE` where it should use the shared test. Whichever lands second adapts. See design.md.
- Out of scope: changing the stale notice's text (after both changes land); refreshing for the IDE extension's own launch or the desktop app; OpenSpec's skills and the plugin install, which stay with `devenv shell`; the plugin's own `CLAUDECODE` tests, in another repository.
