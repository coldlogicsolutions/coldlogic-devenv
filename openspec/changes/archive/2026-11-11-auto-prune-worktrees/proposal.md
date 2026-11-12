# Proposal

## Why

Every merged PR leaves its worktree and branch behind, and a session can't remove them: the sandbox denies writes to a sibling worktree's `.git` and `.claude/hooks|skills`, to `.git/worktrees/*` and to `.git/config`, so `git worktree remove` fails partway and leaves a half-deleted worktree (#73). Those protections stay. Derek cleaned up 15 worktrees and 21 branches by hand on 2026-11-11 and won't do that after every merge, so cleanup has to happen on its own, outside the Bash sandbox.

## What Changes

- New `coldlogic-prune-worktrees` command (`packages/prune-worktrees.sh`, packaged like `session-relink` with a test script that runs at build time). For the repository it runs in, it removes each linked worktree under `<main>.worktrees/` or `<main>/.claude/worktrees/` that is clean, idle and whose work is in main, then deletes its branch and the branch's config section. It also deletes local branches that no worktree has checked out and whose work is in main, and runs `git worktree prune` for half-deleted worktrees.
- "Work is in main" means HEAD is an ancestor of the local `origin/main` (it doesn't fetch, so an SSH remote never asks for a key), or HEAD is contained in the head commit of a merged PR found through `gh-app` (by branch, or by commit for a detached HEAD), which covers squash merges. Without `gh-app` or a network, only the git check is used.
- It never removes the main checkout, a dirty worktree (tracked or untracked changes, or a rebase, merge or cherry-pick in progress), a locked worktree, one with commits that aren't in main, the worktree of the session that ran it, one a process has as its working directory, or one with git or devenv activity in the last 6 hours. It removes with `git worktree remove` (no `--force`), and deletes a branch only if it still points at the commit that was checked.
- Two triggers, neither needing anything from Derek: Claude Code `SessionStart` and `Stop` hooks in the developer profile (hooks run outside the Bash sandbox), which start the prune detached so a session never waits on it; and an enterShell task that does the same from a terminal `devenv shell` (`CLAUDECODE` unset). Runs are rate-limited and serialised by a lock in the git common dir, never fail the hook or the shell, and print nothing; what they did goes to a log in the git common dir.
- Not done: the issue's "in a session it prints what's pending" notice and the plugin convention listing worktrees awaiting cleanup. With automatic cleanup there is nothing for Derek to act on. Neither this repository nor the plugin tells him to clean up by hand today, so there is no instruction to remove.

## Capabilities

### New Capabilities
- `worktree-cleanup`: which of a project's worktrees and branches are removed automatically, the checks that keep live or unmerged work, and when the removal runs (session hook, terminal shell).

### Modified Capabilities
None. The `gate` already builds every module package and so runs its build-time tests; the prune script's tests join them without a requirement change.

## Impact

- New: `packages/prune-worktrees.sh`, `packages/prune-worktrees.nix`, `packages/prune-worktrees-test.sh`.
- `devenv.nix` (developer profile): the package, `SessionStart` and `Stop` hooks under `claude.code.hooks`, and a `coldlogic:prune-worktrees` task before `devenv:enterShell`.
- `README.md`: the "What's here" table gains the command and the hook.
- Every project on the module gets the hook and the task with its next update. Removal is local only: no remote branch is deleted and nothing is pushed.
- Runtime dependencies: git, coreutils, jq, lsof (macOS system `lsof`, or nixpkgs' on Linux), and `gh-app` when present.
