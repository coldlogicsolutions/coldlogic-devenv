# Spec Delta

## ADDED Requirements

### Requirement: A branch create that would set up tracking is denied
In the project's main checkout or a linked worktree of its repository, the guard SHALL deny a `git switch` or `git checkout` that would write tracking configuration: one whose last tracking option is `--track` or `-t`, or one creating a branch from a remote-tracking start point with no tracking option. The reason SHALL name `--no-track`. Anything else SHALL be judged as before.

Tested by: `claude-guard-test.py`, the #45 cases in the "main checkout stays on main" block.

#### Scenario: A new branch from a remote branch
- **WHEN** an allow rule covers `git switch *`, `origin/main` is a remote-tracking branch (loose or in `packed-refs`), and a session in `<main>.worktrees/x` or `<main>/.claude/worktrees/x` runs `git switch -c feat/x origin/main`, `git switch --create feat/x origin/main`, `git switch -C feat/x origin/main` or `git checkout -b feat/x origin/main`
- **THEN** the guard denies it, and the reason says the command would write tracking configuration to `.git/config`, which the sandbox protects, and to add `--no-track`

#### Scenario: Asked for by option
- **WHEN** a session in a linked worktree runs `git switch --track -c feat/x origin/main`, `git switch -t origin/feat/x`, `git checkout --track origin/feat/x` or `git checkout -tb feat/x origin/main`
- **THEN** the guard denies it

#### Scenario: With --no-track
- **WHEN** a session in a linked worktree runs `git switch --no-track -c feat/x origin/main`, `git switch -c feat/x --no-track origin/main` or `git switch --track --no-track -c feat/x origin/main`
- **THEN** the guard doesn't deny it for tracking, and the first two are allowed under a `git switch *` allow rule

#### Scenario: The last tracking option wins
- **WHEN** a session in a linked worktree runs `git switch --no-track --track -c feat/x origin/main`
- **THEN** the guard denies it

#### Scenario: A start point that sets up no tracking
- **WHEN** a session in a linked worktree runs `git switch -c feat/x`, `git switch -c feat/x main`, `git switch -c feat/x origin/main~1`, or `git switch -c feat/x origin/gone` where no such remote-tracking branch exists
- **THEN** the guard doesn't deny it for tracking

#### Scenario: No branch is made
- **WHEN** a session in a linked worktree runs `git switch --detach origin/main`, `git switch --orphan feat/x`, `git switch feat/x` or `git checkout origin/main -- README.md`
- **THEN** the guard doesn't deny it for tracking

#### Scenario: In a chain, behind a wrapper, or after a cd
- **WHEN** a session in a linked worktree runs `git fetch origin main && git switch -c feat/x origin/main`, `devenv shell --quiet -- git switch -c feat/x origin/main`, `bash -c 'git switch -c feat/x origin/main'` or `cd packages/foo && git switch -c feat/x origin/main`
- **THEN** the guard denies it

#### Scenario: From the main checkout, through -C
- **WHEN** a session in the main checkout runs `git -C <main>.worktrees/x switch -c feat/x origin/main`
- **THEN** the guard denies it

#### Scenario: In the main checkout itself
- **WHEN** a session in the main checkout runs `git switch -c feat/x origin/main`
- **THEN** the guard denies it with the main checkout's reason, pointing to a worktree, as before

#### Scenario: A nested repository
- **WHEN** a session in `<main>/vendor/lib`, which has its own `.git` directory, runs `git switch -c feat/x origin/main`
- **THEN** the guard decides it as before

## MODIFIED Requirements

### Requirement: A linked worktree creates and switches branches without a prompt
Under the module's `git switch` allow and ask rules, in a linked worktree of the project, the guard SHALL allow `git switch -c` or `--create <type>/<name> [start]` with `--no-track` or from a start point that sets up no tracking, `git switch <branch>` and `git switch -`, wherever the session is rooted. `-C` SHALL be judged as before, apart from the tracking deny above; the forced forms SHALL still ask.

Tested by: `claude-guard-test.py`, the #44 cases in the "main checkout stays on main" block.

#### Scenario: A new branch from origin/main
- **WHEN** a session rooted in the main checkout or in the worktree runs, in `<main>.worktrees/x` or `<main>/.claude/worktrees/x`, `git switch --no-track -c feat/x origin/main`
- **THEN** the guard allows it, with no permission prompt

#### Scenario: Other untracked create forms
- **WHEN** a session in a linked worktree runs `git switch -c feat/x`, `git switch --no-track --create feat/x origin/main`, `devenv shell --quiet -- git switch --no-track -c feat/x origin/main` or `git fetch origin main && git switch --no-track -c feat/x origin/main`
- **THEN** the guard allows it

#### Scenario: The forced forms
- **WHEN** a session in a linked worktree runs `git switch -f feat/x`, `git switch -fc feat/x` or `git switch --discard-changes feat/x`
- **THEN** the guard asks
