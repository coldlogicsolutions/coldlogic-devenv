# Proposal

## Why

A session can start in a linked worktree (`CLAUDE_PROJECT_DIR` is `<main>.worktrees/x`), and agent sessions do. The guard then takes that worktree for the main checkout and looks for the project's other worktrees in `<main>.worktrees/x.worktrees/` and under `<main>.worktrees/x/.git/worktrees`, where there are none. So no sibling worktree is recognised (#65).

That has two effects, both checked against the code on 2026-11-12:

- **Prompts that shouldn't be.** From a session rooted in `x`, `git status` in `<main>.worktrees/y` asks ("away from the project") where the same command from a session rooted in the main checkout is allowed.
- **Checks that are skipped.** The guard's own protections for a worktree also depend on recognising it:
  - Editing `<main>.worktrees/y/.claude/skills/s/SKILL.md` gets no ask from the guard. `devenv.nix`'s Edit allow rule covers `<main>.worktrees/**`, so the edit goes through with no prompt at all. The same holds for `.claude` in a worktree under `<main>/.claude/worktrees/`.
  - From `<main>.worktrees/y/packages`, `echo x > ../src/b.rs` isn't denied as a shell edit of a project file.

#96 fixed the main-checkout rule for such sessions (`main_checkout()`), and left the rest of #65 open.

## What Changes

- When the session's root is a linked worktree, the guard finds the main checkout through the root's `.git` file and that gitdir's `commondir`, and recognises the project's own worktrees from there: `<main>.worktrees/<name>` and `<main>/.claude/worktrees/<name>`, with the same metadata checks as today (the `.git` file names a directory under `<main>/.git/worktrees` that names it back, and whose `commondir` is `<main>/.git`).
- Everything that is judged by "one of the project's own worktrees" follows: commands there get the decision they would get in the root, a single `git -C` naming the worktree a command runs in is dropped, paths inside count as inside the project, and a shell edit of a file there is denied.
- **Fixed gap:** from a session rooted in a linked worktree, a file tool changing the `.claude` directory of another of the project's worktrees now asks. Before, nothing asked.
- **Fixed gap:** from such a session, a Bash call in a subdirectory of another worktree that writes a file elsewhere in that worktree (`echo x > ../src/b.rs`) is now denied, as it is everywhere else in the project.
- The main checkout itself does not become a recognised checkout for a session rooted in a linked worktree. `git status` there still asks, and `git switch main` there still asks, as #96's tests pin.
- A root whose `.git` isn't a linked worktree's (the main checkout, a submodule, a worktree with no `commondir`, a worktree of a bare repository, no repository) is handled exactly as before.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `claude-guard`: the project's own worktrees are found from the main checkout, also when the session's root is one of them; a sibling of the root is then judged like the root, and its `.claude` directory asks.

## Impact

- `packages/claude-guard.py`: one new helper beside `linked_git_dirs`, and `checkout_of`/`_checkout_of`/`own_worktree` in the same place (lines 1571-1645 on this branch). `main_checkout()` and `decide` are untouched.
- `packages/claude-guard-test.py`: new cases in the "project's own worktrees" block for sessions rooted in a linked worktree, and one skip removed from the #44 loop.
- `README.md`: one sentence in the guard's row.
- `devenv.nix`: no change. Its Edit allow rule already covers the sibling worktrees; the guard's ask now applies there too.
- Sessions rooted in a linked worktree: fewer prompts in sibling worktrees, and two new decisions (the `.claude` ask, the shell-edit deny) where there were none.
- Closes #65.
