# Spec Delta

## ADDED Requirements

### Requirement: The project's own worktrees are recognised by their git metadata
The guard SHALL count a directory as one of the project's own worktrees, wherever it sits, only when its `.git` file names a directory under the project's `.git/worktrees`, that directory's `gitdir` names it back, and its `commondir` resolves to the project's `.git`.

Tested by: `claude-guard-test.py`, the "project's own worktrees" block.

#### Scenario: An agent worktree beside the project
- **WHEN** `<project>.worktrees/x` was made by `git worktree add` from the project
- **THEN** the guard counts it as one of the project's own worktrees

#### Scenario: Metadata that doesn't name the directory back
- **WHEN** a directory's `.git` file names `<project>/.git/worktrees/x`, but that directory's `gitdir` names another directory
- **THEN** the guard doesn't count it as one of the project's worktrees

### Requirement: The project's own worktrees are judged like its root
At the top of one of the project's own worktrees, or in a subdirectory of one with no other repository in between, a command SHALL get the same decision it would get in the project root. Paths inside such a worktree SHALL count as inside the project.

Tested by: `claude-guard-test.py`, the "project's own worktrees" block.

#### Scenario: git status in a sibling worktree
- **WHEN** an allow rule covers `git status *` and a session in `<project>.worktrees/x`, a linked worktree of the project, runs `git status`
- **THEN** the guard allows it

#### Scenario: Branch creation in a sibling worktree
- **WHEN** an allow rule covers `git switch *` and a session in `<project>.worktrees/x` runs `git switch -c feat/y`
- **THEN** the guard allows it

#### Scenario: Forced switch in a sibling worktree
- **WHEN** an ask rule covers `git switch -f *` and a session in `<project>.worktrees/x` runs `git switch -f main`
- **THEN** the guard asks

#### Scenario: Adding a file in a subdirectory of a sibling worktree
- **WHEN** an allow rule covers `git add *` and a session in `<project>.worktrees/x/packages` runs `git add a.py`
- **THEN** the guard allows it

#### Scenario: A subdirectory of a worktree under .claude
- **WHEN** an allow rule covers `git log *` and a session in `<project>/.claude/worktrees/x/src` runs `git log`
- **THEN** the guard allows it

#### Scenario: A directory that only claims to be a worktree
- **WHEN** a directory's `.git` file names `<project>/.git/worktrees/x`, whose `gitdir` names another directory, and a session there runs `git status`
- **THEN** the guard returns no allow

#### Scenario: A worktree whose commondir leads elsewhere
- **WHEN** a worktree's `.git/worktrees/x/commondir` resolves to a directory other than the project's `.git`, and a session there runs `git status`
- **THEN** the guard returns no allow

#### Scenario: Another repository's worktree
- **WHEN** a session runs `git status` in a worktree of a different repository
- **THEN** the guard returns no allow

#### Scenario: A nested repository inside a sibling worktree
- **WHEN** a session runs `git status` in `<project>.worktrees/x/vendor/lib`, which has its own `.git` directory
- **THEN** the guard returns no allow

#### Scenario: A path out of a sibling worktree
- **WHEN** a session in `<project>.worktrees/x` runs `cat ../y/README.md`
- **THEN** the guard returns no allow

#### Scenario: A relative program below a worktree's top
- **WHEN** an allow rule covers `scripts/check.sh` and a session in `<project>.worktrees/x/packages` runs `scripts/check.sh`
- **THEN** the guard asks

### Requirement: git -C naming one of the project's checkouts is dropped before rules match
When a command runs at the top of the project or one of its own worktrees, the guard SHALL drop a `git -C <dir>` whose `<dir>` is the top of the project or of one of its own worktrees, before allow rules match. Any other `-C` value SHALL stay, so the command matches no allow rule.

Tested by: `claude-guard-test.py`, the "project's own worktrees" block.

#### Scenario: -C naming the worktree the session runs in
- **WHEN** an allow rule covers `git status *` and a session at the top of `<project>.worktrees/x` runs `git -C <project>.worktrees/x status`
- **THEN** the guard allows it

#### Scenario: -C naming another of the project's checkouts
- **WHEN** an allow rule covers `git log *` and a session at the project root runs `git -C <project>.worktrees/x log --oneline`
- **THEN** the guard allows it

#### Scenario: -C naming a repository outside the project
- **WHEN** an allow rule covers `git status *` and a session runs `git -C /elsewhere/repo status`
- **THEN** the guard returns no allow

#### Scenario: -C from a subdirectory
- **WHEN** a session in `<project>/packages` runs `git -C <project>.worktrees/x status`
- **THEN** the guard returns no allow

## MODIFIED Requirements

### Requirement: File tools ask before changing .git or Claude Code configuration
The guard SHALL deny file-tool writes inside a `.git` directory. It SHALL ask before file tools change the project's `.claude` directory, except inside the checkouts under `.claude/worktrees/<name>/`. That directory itself, and the `.claude` directory of any of the project's own worktrees, SHALL still ask.

Tested by: `claude-guard-test.py`, `FILES`, the `.claude` block and the "project's own worktrees" block.

#### Scenario: Writing git config
- **WHEN** a session writes `/p/nested/.git/config`
- **THEN** the guard denies it

#### Scenario: Editing project settings
- **WHEN** a session edits `<root>/.claude/settings.json` and it is a regular file
- **THEN** the guard asks (when it is devenv's symlink into the Nix store, the guard resolves it outside the project and leaves the call to Claude Code's rules)

#### Scenario: Writing inside a worktree under .claude
- **WHEN** a session writes `<root>/.claude/worktrees/x/src/main.rs`
- **THEN** the guard leaves the call to Claude Code's rules

#### Scenario: Editing settings inside a worktree
- **WHEN** a session edits `<root>/.claude/worktrees/x/.claude/settings.json`
- **THEN** the guard asks

#### Scenario: Editing a skill inside a sibling worktree
- **WHEN** a session in `<project>.worktrees/x` edits `<project>.worktrees/x/.claude/skills/y/SKILL.md` and it is a regular file
- **THEN** the guard asks

#### Scenario: Editing the main checkout's settings from a sibling worktree
- **WHEN** a session in `<project>.worktrees/x` edits `<project>/.claude/settings.local.json`
- **THEN** the guard asks

#### Scenario: Writing source in a sibling worktree
- **WHEN** a session in `<project>.worktrees/x` writes `<project>.worktrees/x/src/main.rs`
- **THEN** the guard leaves the call to Claude Code's rules
