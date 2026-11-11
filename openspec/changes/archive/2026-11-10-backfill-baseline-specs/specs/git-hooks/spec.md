# Spec Delta

## Purpose

The pre-commit hooks the module and its profiles turn on, and where git looks for them, so that each worktree of a project runs its own hooks.

## ADDED Requirements

### Requirement: Nix files are formatted before commit
The developer profile SHALL enable the `nixfmt` pre-commit hook.

Tested by: the hook itself, on every commit to this repository.

#### Scenario: Unformatted Nix
- **WHEN** a developer commits a `.nix` file that `nixfmt` would change
- **THEN** the commit fails

### Requirement: Each worktree uses its own hooks directory
Before the git hooks are installed, the shell SHALL set `extensions.worktreeConfig` and a per-worktree `core.hooksPath` pointing at that worktree's own git dir's `hooks`. It SHALL write git config only when a value differs, since a session's sandbox can't write `.git/config`.

Tested by: none.

#### Scenario: Two worktrees
- **WHEN** a developer enters the shell in worktree A, then in worktree B
- **THEN** a commit in A still runs hooks built from A's `.pre-commit-config.yaml`

#### Scenario: Already configured
- **WHEN** both values are already set
- **THEN** the shell writes nothing to git config
