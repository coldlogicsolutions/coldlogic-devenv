# Spec Delta

## MODIFIED Requirements

### Requirement: File tools ask before changing .git or Claude Code configuration
The guard SHALL deny file-tool writes inside a `.git` directory. It SHALL ask before file tools change the project's `.claude` directory, except inside the checkouts under `.claude/worktrees/<name>/`. That directory itself, and the `.claude` directory of any of the project's own worktrees, SHALL still ask. A path whose last component is a symlink SHALL ask when it sits in such a `.claude` directory, wherever the link leads, and when the link leads into one. Reads SHALL be left alone.

Tested by: `claude-guard-test.py`, `FILES`, the `.claude` block, the "linked file in `.claude`" block and the "project's own worktrees" block.

#### Scenario: Writing git config
- **WHEN** a session writes `/p/nested/.git/config`
- **THEN** the guard denies it

#### Scenario: Editing project settings
- **WHEN** a session edits `<root>/.claude/settings.json` and it is a regular file
- **THEN** the guard asks

#### Scenario: Editing the generated settings link
- **WHEN** a session edits or writes `<root>/.claude/settings.json` and it is devenv's symlink into the Nix store
- **THEN** the guard asks

#### Scenario: A settings link whose target is missing
- **WHEN** a session writes `<root>/.claude/settings.local.json` and it is a symlink to a file outside the project that doesn't exist
- **THEN** the guard asks

#### Scenario: A link elsewhere that leads into .claude
- **WHEN** a session edits `<root>/alias.json` and it is a symlink to `<root>/.claude/settings.local.json`
- **THEN** the guard asks

#### Scenario: A link outside .claude that leads out of the project
- **WHEN** a session edits `<root>/notes.json` and it is a symlink to a file outside the project
- **THEN** the guard leaves the call to Claude Code's rules

#### Scenario: Reading the generated settings link
- **WHEN** a session reads `<root>/.claude/settings.json` and it is devenv's symlink into the Nix store
- **THEN** the guard leaves the call to Claude Code's rules

#### Scenario: Writing inside a worktree under .claude
- **WHEN** a session writes `<root>/.claude/worktrees/x/src/main.rs`
- **THEN** the guard leaves the call to Claude Code's rules

#### Scenario: Editing settings inside a worktree
- **WHEN** a session edits `<root>/.claude/worktrees/x/.claude/settings.json`
- **THEN** the guard asks

#### Scenario: Editing a skill inside a sibling worktree
- **WHEN** a session in `<project>.worktrees/x` edits `<project>.worktrees/x/.claude/skills/y/SKILL.md` and it is a regular file
- **THEN** the guard asks

#### Scenario: Editing a sibling worktree's generated settings link
- **WHEN** a session in `<project>` or in `<project>.worktrees/x` edits `<project>.worktrees/x/.claude/settings.json` and it is a symlink to a file outside the project
- **THEN** the guard asks

#### Scenario: Editing the main checkout's settings from a sibling worktree
- **WHEN** a session in `<project>.worktrees/x` edits `<project>/.claude/settings.local.json`
- **THEN** the guard asks

#### Scenario: Another repository's settings link
- **WHEN** a session in `<project>.worktrees/x` edits `<other>.worktrees/w/.claude/settings.json`, in a worktree of another repository, whether it is a regular file, a symlink or missing
- **THEN** the guard leaves the call to Claude Code's rules

#### Scenario: Writing source in a sibling worktree
- **WHEN** a session in `<project>.worktrees/x` writes `<project>.worktrees/x/src/main.rs`
- **THEN** the guard leaves the call to Claude Code's rules
