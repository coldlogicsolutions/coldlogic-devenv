# git-hooks Specification

## Purpose
The pre-commit hooks the module and its profiles turn on, and where git looks for them, so that each worktree of a project runs its own hooks.

## Requirements

### Requirement: Nix files are formatted before commit
The developer profile SHALL enable the `nixfmt` pre-commit hook.

Tested by: the hook itself, on every commit to this repository.

#### Scenario: Unformatted Nix
- **WHEN** a developer commits a `.nix` file that `nixfmt` would change
- **THEN** the commit fails

### Requirement: The shell leaves the hooks path alone
The shell SHALL NOT write `core.hooksPath`, `extensions.worktreeConfig` or any other git config. Hooks SHALL be installed in, and run from, the hooks directory git resolves for the worktree, and a commit SHALL run them with its own worktree's `.pre-commit-config.yaml`. This relies on a devenv at or after 2026-10-19.

Tested by: none in the gate; manually, by the checklist in the #64 follow-up.

#### Scenario: Two worktrees sharing a hooks directory
- **WHEN** a developer enters the shell in worktree A, then in worktree B, and both resolve the main checkout's `.git/hooks`
- **THEN** a commit in A still runs hooks built from A's `.pre-commit-config.yaml`

#### Scenario: A fresh worktree in a session
- **WHEN** a session enters the shell in a worktree it entered with EnterWorktree, whose `config.worktree` the sandbox protects
- **THEN** the shell writes no git config, no task fails, and `devenv:enterShell` runs

#### Scenario: A worktree with an older per-worktree hooks path
- **WHEN** the shell is entered in a worktree whose `config.worktree` already names its own hooks directory
- **THEN** the setting is left as it is, and hooks are installed in and run from that directory

### Requirement: A session skips a hook install it can't write
Inside a session, the shell SHALL skip `devenv:git-hooks:install`, without failing it, when the hooks directory git resolves, or an expected hook already in it, can't be written. Anywhere else the install SHALL run as devenv defines it.

Tested by: `packages/session-shell-test.sh` at build; the status in `devenv.nix` is untested.

#### Scenario: A worktree the session works in
- **WHEN** a session enters the shell in a worktree made with EnterWorktree or for a subagent, whose hooks directory is the main checkout's `.git/hooks`, which holds an executable `pre-commit` and which the sandbox protects
- **THEN** `devenv:git-hooks:install` is skipped, `devenv:enterShell` runs, and a commit there runs that hook with the worktree's own `.pre-commit-config.yaml`

#### Scenario: A hooks directory the session can write
- **WHEN** a session enters the shell in a worktree whose `core.hooksPath` names a directory the sandbox lets it write
- **THEN** `devenv:git-hooks:install` runs and installs the hook there

#### Scenario: The main checkout in a session
- **WHEN** a session enters the shell in the main checkout after a module update changed the hooks configuration, and the sandbox protects `.git/hooks`
- **THEN** the install is skipped without failing, the installed hook stays, and nothing is printed about it

#### Scenario: Outside a session
- **WHEN** a developer enters the shell from a terminal
- **THEN** `devenv:git-hooks:install` runs whatever the hooks directory's permissions are

### Requirement: A missing hook is reported
After the hook install has run or been skipped, when an expected hook is missing from the hooks directory git resolves, or isn't executable, the shell SHALL print a `coldlogic:` notice naming the hook and the directory. Inside a session the notice SHALL follow the session-notices once-per-session rule. With every expected hook in place the shell SHALL print nothing about hooks.

Tested by: `packages/session-shell-test.sh` at build; the task in `devenv.nix` is untested.

#### Scenario: No hook where one can't be installed
- **WHEN** a session's shell skipped the install and the hooks directory has no executable `pre-commit`
- **THEN** stderr shows one `coldlogic:` notice that commits there run no `pre-commit` hook, naming the directory and saying to enter the shell once from a terminal

#### Scenario: The hook is there
- **WHEN** a session's shell skipped the install and the hooks directory holds an executable `pre-commit`
- **THEN** the shell prints nothing about hooks

#### Scenario: An older hooks path that names a missing directory
- **WHEN** a worktree's `core.hooksPath` names a directory that doesn't exist, and the install didn't create a hook there
- **THEN** the notice names that directory

#### Scenario: No hook expected
- **WHEN** every enabled hook is in the manual stage, so devenv installs none
- **THEN** the shell prints no missing-hook notice, in a session or a terminal
