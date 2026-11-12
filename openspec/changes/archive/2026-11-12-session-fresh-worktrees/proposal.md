# Proposal

## Why

A Claude Code session that works in a fresh worktree gets a broken, noisy shell (#93 group 2). In a worktree the session entered with EnterWorktree, the sandbox refuses the `core.hooksPath` write, so `coldlogic:worktree-hooks-path` fails and takes `devenv:git-hooks:install` and `devenv:enterShell` with it (#67). Every shell there also prints two notices about files that worktree doesn't need: `.claude/settings.json`, `.mcp.json` and the OpenSpec skills are read from the checkout the session started in (#78). And `git switch -c x origin/main` is allowed although it writes tracking config to `.git/config`, which the sandbox protects, so it fails partway (#45).

## What Changes

- **BREAKING**: `coldlogic:worktree-hooks-path` is removed. The shell no longer gives each worktree its own `core.hooksPath`, and writes no git config at all. Worktrees use the hooks directory git resolves, normally the main checkout's `.git/hooks`. Since devenv's change of 2026-10-19 the hook there reads the configuration of the worktree that commits, so the step is no longer needed. A project must pin a devenv at or after that date.
- In a session, `devenv:git-hooks:install` is skipped when the hooks directory git resolves can't be written. Without this, removing the first failure only moves it one task later: the main checkout's `.git/hooks` is protected by the sandbox too. Commits keep running the hook already installed there.
- The shell says so when the hooks directory commits will use has no hook. With a hook in place it prints nothing about hooks.
- A worktree that already has a per-worktree `core.hooksPath` keeps it. The shell doesn't unset it.
- Generated settings gain one environment variable, `COLDLOGIC_SESSION_ROOT`, naming the checkout they were generated for. A shell in a session uses it to tell whether it runs in the checkout the session reads its Claude Code files from.
- In a session whose Claude Code files come from another checkout, the shell no longer reports `.claude/settings.json` or `.mcp.json` as missing or out of date, and no longer tries to generate the OpenSpec skills or warns about them. Where the session does read them from this checkout, or that can't be told, everything is reported as today.
- In a session, each distinct notice is printed once per session and checkout, not on every shell: the generated-files notice, the OpenSpec skills warning, the missing-hook notice and the "coldlogic-devenv is behind" warning. Outside a session nothing changes.
- The generated-files notice says to restart the sessions before any of them runs another command (#94's finding). Otherwise its text is unchanged.
- The guard denies a `git switch` or `git checkout` in the project's repository that would set up tracking (an explicit `--track`/`-t`, or a new branch from a remote-tracking start point without `--no-track`), and names `--no-track`. Today it allows them.
- The new shell logic lives in one tested script, `packages/session-shell.sh`, not inline in `devenv.nix`.
- The two `session-permissions` requirements marked "Tested by: manually, pending in #64" point at the #64 follow-up, whose checklist is this change's last task section. #64 itself is superseded.

## Capabilities

### New Capabilities

- `session-notices`: when a `devenv shell` inside a Claude Code session prints a notice: once per session and checkout for each distinct notice, and only about files that matter to that session in that checkout.

### Modified Capabilities

- `git-hooks`: the per-worktree hooks path requirement is removed; the shell writes no git config; in a session the hook install is skipped where the hooks directory can't be written; a missing hook is reported.
- `generated-files`: the notice leaves out the files only a session started in the checkout reads, when this session reads them elsewhere; it is printed once per session; its restart advice is tightened.
- `openspec-files`: in a session that reads its Claude Code files from another checkout, the skills are neither generated nor warned about; the warning is printed once per session.
- `claude-guard`: a branch create that would set up tracking is denied, naming `--no-track`.
- `session-permissions`: the generated settings set `COLDLOGIC_SESSION_ROOT`; two "Tested by" lines point at the #64 follow-up.
- `module-updates`: in a session the behind warning is printed once per session.

## Impact

- `devenv.nix`: `coldlogic:worktree-hooks-path` removed, a new status on `devenv:git-hooks:install`, a new `coldlogic:hooks-check` task, `coldlogic:generated-files-stale`, `coldlogic:openspec-files`, `coldlogic:setup-freshness`, and `claude.code.env`.
- New `packages/session-shell.sh`, `packages/session-shell-test.sh`, `packages/session-shell.nix`. `scripts/check.sh` needs no change: the build step runs the new tests.
- `packages/claude-guard.py`, `packages/claude-guard-test.py`.
- The settings' store path changes (new env entry), so every checkout needs one terminal `devenv shell` and a session restart after the lock bump, as for any settings change. A session started before that has no `COLDLOGIC_SESSION_ROOT` and gets today's notices, still once per session.
- Sessions that created tracking branches with `git switch -c x origin/main` are now told to add `--no-track`.
- Importing projects need a devenv at or after 2026-10-19 in their `devenv.lock`. On an older one, worktrees sharing a hooks directory run the hook configuration of whichever worktree installed last.
- The parallel `claude-wrapper` change (#101) redefines the module's session test. This change keeps its own test in one function so the second to land switches it in one edit (design.md, decision 1).
- Out of scope: #65 (sibling worktree recognition in the guard), #97 (denying the hooks-path write in the sandbox; with the write gone it may no longer be needed), the other commands that write tracking config (`git branch`, `git worktree add -b`, `git switch <remote-only branch>`, `git push -u`), which go to the tracking follow-up, and the plugin install warnings.
