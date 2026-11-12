# Spec Delta

## ADDED Requirements

### Requirement: The main checkout stays on its default branch
Where a command runs in the project's main checkout, after any `git -C`, the guard SHALL deny a `git switch` or `git checkout` that creates a branch, detaches HEAD, or checks out anything but the default branch (`origin/HEAD`, else an existing `main` or `master`, else `main`), in any spelling git accepts, anywhere in a call, pointing to a worktree. A linked worktree or nested repository SHALL be judged as before.

Tested by: `claude-guard-test.py`, the "main checkout stays on main" block.

#### Scenario: Creating a branch in the main checkout
- **WHEN** a session at the main checkout's top or in a subdirectory runs `git switch -c feat/x`, `git switch --cr feat/x`, `git switch -qc feat/x`, `git checkout -b feat/x` or `git checkout -qb feat/x`
- **THEN** the guard denies it with "Branch work goes in a worktree: EnterWorktree, or isolation: \"worktree\" on a subagent (git.md)."

#### Scenario: Switching to another branch, a commit or a tag
- **WHEN** a session in the main checkout runs `git switch feat/x`, `git switch -`, `git switch --detach origin/main`, `git checkout v1.0`, `git checkout abc1234` or `git checkout feat/x --`
- **THEN** the guard denies it

#### Scenario: In a chain, behind a wrapper, or through -C
- **WHEN** a session runs `git status && git switch -c feat/x`, `devenv shell --quiet -- git switch -c feat/x`, `bash -c 'git switch -c feat/x'` or, from a linked worktree, `git -C <main> switch -c feat/x`
- **THEN** the guard denies it

#### Scenario: Back to main
- **WHEN** an allow rule covers `git switch *` and a session in the main checkout runs `git switch main`
- **THEN** the guard allows it

#### Scenario: A session started in a linked worktree
- **WHEN** the session's project root is a linked worktree and a command in the main checkout runs `git switch -c feat/x`
- **THEN** the guard denies it, finding the main checkout through the worktree's `.git` file and `commondir`

#### Scenario: A harness worktree
- **WHEN** an allow rule covers `git switch *` and a session in `<main>.worktrees/x` or `<main>/.claude/worktrees/x` runs `git switch --no-track -c feat/x origin/main`
- **THEN** the guard allows it

#### Scenario: A nested repository
- **WHEN** a session in `<main>/vendor/lib`, which has its own `.git` directory, runs `git switch -c feat/x`
- **THEN** the guard doesn't deny it

#### Scenario: Another default branch
- **WHEN** `origin/HEAD` names `trunk` and a session in the main checkout runs `git switch trunk` or `git switch main`
- **THEN** the guard allows the first and denies the second

#### Scenario: No origin/HEAD
- **WHEN** a repository has no `origin/HEAD` and only a `master` branch, loose or packed, and a session in its main checkout runs `git switch master` or `git switch main`
- **THEN** the guard allows the first and denies the second

### Requirement: File restores in the main checkout are not branch switches
In the main checkout, the guard SHALL NOT deny a `git checkout` that only restores files or stays put: paths after `--`, a tree-ish and paths, `-p`, `--pathspec-from-file`, `HEAD` or `@`, or a single operand that holds a glob or names an existing path from where it runs and no branch, tag or remote branch. Any other single operand SHALL count as a branch, commit or tag.

Tested by: `claude-guard-test.py`, the "main checkout stays on main" block.

#### Scenario: Restoring a file
- **WHEN** a session in the main checkout runs `git checkout -- README.md`, `git checkout HEAD -- README.md`, `git checkout feat/x -- README.md`, `git checkout origin/main README.md`, `git checkout README.md`, `git checkout .` or `git checkout -p`
- **THEN** the guard doesn't deny it

#### Scenario: A file that is gone
- **WHEN** a session in the main checkout runs `git checkout missing.txt`, and no such path exists
- **THEN** the guard denies it as a checkout, and names `git checkout -- <path>` and `git restore`

#### Scenario: HEAD
- **WHEN** a session in the main checkout runs `git checkout HEAD` or `git checkout @`
- **THEN** the guard doesn't deny it, and still denies `git checkout HEAD~1`

#### Scenario: A path that is also a ref
- **WHEN** the main checkout has a `docs/` directory and a `docs` branch, tag or remote branch (loose or in `packed-refs`), and a session there runs `git checkout docs`
- **THEN** the guard denies it, as git checks out the ref, and doesn't deny `git checkout -- docs`

### Requirement: A branch switch after a cd is judged where the cd leads
After a `cd` or `pushd` to an existing literal directory, the guard SHALL judge a `git switch` or `git checkout` from there; a cd in a subshell, pipeline stage or background SHALL NOT carry past it. Where it can't tell (another cd, or `env -C`/`sudo -D`, also through what they run), one that would leave the default branch SHALL ask, unless an absolute `git -C` names where. A deny in the call SHALL win.

Tested by: `claude-guard-test.py`, the "main checkout stays on main" block.

#### Scenario: cd into the main checkout
- **WHEN** a session in a linked worktree runs `cd <main> && git switch -c feat/x`, or a session in the main checkout runs `cd sub && git switch -c feat/x`
- **THEN** the guard denies it

#### Scenario: cd within a linked worktree
- **WHEN** a session in a linked worktree runs `cd packages/foo && git switch --no-track -c feat/x origin/main`
- **THEN** the guard doesn't ask or deny it for the main checkout

#### Scenario: A cd in a subshell
- **WHEN** a session in the main checkout runs `(cd <worktree>); git switch -c feat/x`
- **THEN** the guard denies it

#### Scenario: Where the cd leads can't be read
- **WHEN** a session runs `cd "$D" && git switch -c feat/x`, `cd - && git switch -c feat/x`, `env -C <main> git switch -c feat/x` or `env -C <main> bash -c 'git switch -c feat/x'`
- **THEN** the guard asks

#### Scenario: A deny elsewhere wins
- **WHEN** a session runs `cd "$D"; git switch -c feat/x; cargo publish`, and a deny rule covers `cargo publish *`
- **THEN** the guard denies it

#### Scenario: An absolute -C after a cd
- **WHEN** a session runs `cd sub && git -C <main> switch -c feat/x`, or, in the main checkout, `cd /tmp && git -C <main> switch -c feat/x`
- **THEN** the guard denies it

#### Scenario: A cd after the switch
- **WHEN** a session in the main checkout runs `git switch -c feat/x && cd sub`
- **THEN** the guard denies it

### Requirement: A forced worktree remove and worktree add -B get no allow
The guard SHALL give no allow to `git worktree remove` with `-f` in any cluster or any prefix git accepts of `--force`, or to `git worktree add -B`, alone or in a cluster (`-qB`), so an allow rule naming `git worktree` asks.

Tested by: `claude-guard-test.py`, the #87 cases.

#### Scenario: A forced remove in a shorter spelling
- **WHEN** an allow rule covers `git worktree *` and a session runs `git worktree remove --fo wt`, `git worktree remove -f wt` or `git worktree remove wt --forc`
- **THEN** the guard asks, and still allows `git worktree remove wt`

#### Scenario: Resetting a branch with -B
- **WHEN** an allow rule covers `git worktree *` and a session runs `git worktree add -B feat/x wt origin/main` or `git worktree add -qB feat/x wt origin/main`
- **THEN** the guard asks, and still allows `git worktree add -b feat/x wt origin/main`

### Requirement: A linked worktree creates and switches branches without a prompt
Under the module's `git switch` allow and ask rules, in a linked worktree of the project, the guard SHALL allow `git switch -c` or `--create <type>/<name> [start]` with `--no-track` or no tracking, `git switch <branch>` and `git switch -`, wherever the session is rooted. `--track` and `-C` SHALL be judged as before; the forced forms SHALL still ask.

Tested by: `claude-guard-test.py`, the #44 cases in the "main checkout stays on main" block.

#### Scenario: A new branch from origin/main
- **WHEN** a session rooted in the main checkout or in the worktree runs, in `<main>.worktrees/x` or `<main>/.claude/worktrees/x`, `git switch --no-track -c feat/x origin/main`
- **THEN** the guard allows it, with no permission prompt

#### Scenario: Other untracked create forms
- **WHEN** a session in a linked worktree runs `git switch -c feat/x`, `git switch --create feat/x origin/main`, `devenv shell --quiet -- git switch --no-track -c feat/x origin/main` or `git fetch origin main && git switch --no-track -c feat/x origin/main`
- **THEN** the guard allows it

#### Scenario: The forced forms
- **WHEN** a session in a linked worktree runs `git switch -f feat/x`, `git switch -fc feat/x` or `git switch --discard-changes feat/x`
- **THEN** the guard asks
