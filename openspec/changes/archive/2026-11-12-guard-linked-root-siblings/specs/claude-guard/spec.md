# Spec Delta

## MODIFIED Requirements

### Requirement: The project's own worktrees are recognised by their git metadata
The guard SHALL count a directory as one of the project's own worktrees only when it is `<project>/.claude/worktrees/<name>` or `<project>.worktrees/<name>`, its `.git` file names a directory under the project's `.git/worktrees` that names it back, and that directory's `commondir` exists and resolves to the project's `.git`. `<project>` SHALL be the session's root or, when the root is a linked worktree, the main checkout that the root's `.git` file and that directory's `commondir` name. Relative paths in these files SHALL be read as git reads them.

Tested by: `claude-guard-test.py`, the "project's own worktrees" block.

#### Scenario: An agent worktree beside the project
- **WHEN** `<project>.worktrees/x` was made by `git worktree add` from the project
- **THEN** the guard counts it as one of the project's own worktrees

#### Scenario: Metadata that doesn't name the directory back
- **WHEN** a directory's `.git` file names `<project>/.git/worktrees/x`, but that directory's `gitdir` names another directory
- **THEN** the guard doesn't count it as one of the project's worktrees

#### Scenario: A worktree of the project somewhere else
- **WHEN** a session runs `git status` in `/elsewhere/wt`, a linked worktree of the project outside both places
- **THEN** the guard returns no allow

#### Scenario: Relative worktree paths
- **WHEN** a sibling worktree's `.git` file and its `gitdir` back-pointer hold relative paths (git's `worktree.useRelativePaths`), and a session there runs `git status`
- **THEN** the guard allows it

#### Scenario: A worktree with no commondir
- **WHEN** a sibling worktree's `.git/worktrees/x` has no `commondir`, and a session there runs `git status`
- **THEN** the guard returns no allow

#### Scenario: A sibling of a root that is a linked worktree
- **WHEN** the session's root is `<main>.worktrees/x`, a linked worktree of the main checkout `<main>`, and `<main>.worktrees/y` and `<main>/.claude/worktrees/n` were made by `git worktree add` from it
- **THEN** the guard counts `<main>.worktrees/y` and `<main>/.claude/worktrees/n` as the project's own worktrees

#### Scenario: A root whose .git file is relative
- **WHEN** the session's root is `<main>.worktrees/x`, whose `.git` file holds a relative path, an allow rule covers `git status *`, and a session in `<main>.worktrees/y` runs `git status`
- **THEN** the guard allows it

#### Scenario: The same checks from a root that is a linked worktree
- **WHEN** the session's root is `<main>.worktrees/x` and a session runs `git status` in a directory that only claims to be a worktree, a worktree whose `commondir` leads elsewhere, another repository's worktree, or a worktree of the project outside both places
- **THEN** the guard returns no allow

#### Scenario: A root whose .git file names no main checkout
- **WHEN** the session's root has a `.git` file whose directory has no `commondir` (a broken worktree, a submodule), or whose `commondir` isn't a checkout's `.git` directory (a worktree of a bare repository)
- **THEN** the guard takes the root itself for `<project>`, as before: a command in the root is judged as in any project root, and `git status` in `<main>.worktrees/y` returns no allow

### Requirement: The project's own worktrees are judged like its root
At the top of one of the project's own worktrees, or in a subdirectory of one with no other repository in between, a command SHALL get the same decision it would get in the project root. Paths inside such a worktree SHALL count as inside the project. This SHALL hold wherever the session's root is: the main checkout, or one of the project's own worktrees. The main checkout SHALL NOT count as one of the project's own worktrees for a session whose root is a linked worktree.

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

#### Scenario: A sibling worktree, from a session rooted in a linked worktree
- **WHEN** the session's root is `<main>.worktrees/x`, allow rules cover `git status *`, `git log *` and `git add *`, and a session runs `git status` in `<main>.worktrees/y`, `git add a.py` in `<main>.worktrees/y/packages`, or `git log` in `<main>/.claude/worktrees/n/src`
- **THEN** the guard allows it

#### Scenario: A sibling worktree's .claude, from a session rooted in a linked worktree
- **WHEN** the session's root is `<main>.worktrees/x` and a session edits `<main>.worktrees/y/.claude/skills/s/SKILL.md`, a regular file, or `<main>/.claude/worktrees/n/.claude/settings.json`
- **THEN** the guard asks

#### Scenario: Source and .git in a sibling worktree, from a session rooted in a linked worktree
- **WHEN** the session's root is `<main>.worktrees/x` and a session writes `<main>.worktrees/y/src/main.rs` or `<main>.worktrees/y/.git`
- **THEN** the guard leaves the first to Claude Code's rules and denies the second

#### Scenario: A shell edit in a sibling worktree, from a session rooted in a linked worktree
- **WHEN** the session's root is `<main>.worktrees/x` and a session in `<main>.worktrees/y/packages` runs `echo x > ../src/b.rs`, which names no scratch file
- **THEN** the guard denies it, as a Bash call changing a project file

#### Scenario: -C naming a sibling, from a session rooted in a linked worktree
- **WHEN** the session's root is `<main>.worktrees/x`, an allow rule covers `git status *`, and a session at the top of `<main>.worktrees/x` runs `git -C <main>.worktrees/y status`
- **THEN** the guard returns no allow, while the same command at the top of `<main>.worktrees/y` is allowed

#### Scenario: The main checkout, from a session rooted in a linked worktree
- **WHEN** the session's root is `<main>.worktrees/x`, allow rules cover `git status *` and `git switch *`, and a session in `<main>` runs `git status` or `git switch main`
- **THEN** the guard asks
