# Proposal

## Why

Subagents started with `isolation: worktree` can't do routine work without Derek. The user's `WorktreeCreate` hook (`~/.claude/hooks/worktree-create.sh`) puts them in `<project>.worktrees/<name>`, beside the checkout. There the guard asks for every `git status`, `git log`, `git add` and `git switch -c`, and the sandbox won't let `devenv shell` write the worktree's `.devenv` or a fresh `/tmp/devenv-<hash>`. So the agent can't run the gate, `gh-app` or commit (#42, #44, #45).

## What Changes

- The guard treats a linked worktree of the project's own repository as a checkout of the project, wherever it sits. A worktree counts when its `.git` file names a directory under the project's `.git/worktrees`, that directory names the worktree back, and its `commondir` resolves to the project's `.git`. Commands at its top or in its subdirectories, and paths inside it, are judged as they would be in the project root. Today only `.claude/worktrees/<name>` tops get that, and paths in a sibling worktree count as outside the project.
- The guard drops `git -C <dir>` before matching rules when `<dir>` is the top of the project or one of its own worktrees and the command already runs at the top of one of them. `git -C <anything else>` still matches no allow rule.
- The guard asks before a file tool changes a `.claude` directory inside a sibling worktree, as it already does for a worktree under `.claude/worktrees`.
- The generated settings let the sandbox write the project's sibling worktree directory (`<main checkout>.worktrees`) and allow Edit there without a prompt. The main checkout is worked out from the `.git` file when the shell is entered from a worktree.
- The generated settings let the sandbox write devenv's per-checkout runtime directories, `/tmp/devenv-*` (and `/private/tmp/devenv-*`). This is broader than this repo's worktrees: see design.md, "Risks".
- Out of scope: `.git/config` writes from upstream tracking (`git switch -c x origin/main`, `git worktree add -b ... origin/main`, `git push -u`). The sandbox still blocks them on purpose. Agents use `--no-track` or `--detach`, as the existing convention says.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `claude-guard`: plain-command allows, path checks and `.claude` asks cover the project's own linked worktrees wherever they sit, and `git -C` naming one of them.
- `session-permissions`: the Edit allow rule and the sandbox's allowWrite cover the project's sibling worktree directory and devenv's runtime directories.

## Impact

- `packages/claude-guard.py`: `away_from_root`, `at_top`, `own_worktree`, `resolve`, `normalize_git`, plus a new helper for the checkout a command runs in.
- `packages/claude-guard-test.py`: new cases for sibling worktrees, their subdirectories, look-alikes and `git -C`. The guard build runs them (`packages/claude-guard.nix`).
- `devenv.nix`: `rules.Edit.allow` and `sandbox.filesystem.allowWrite` in the developer profile.
- `README.md`: the guard row and the worktree notes.
- Every adopting project gets the wider allowWrite on its next update. It is scoped to that project's own `<checkout>.worktrees` directory.
- Closes #42 and #44, and the agent-worktree part of #45. #45's `.git/config` item stays open.
