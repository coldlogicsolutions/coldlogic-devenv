# Spec Delta

## Purpose

Removes a project's merged worktrees and branches on its own, outside the Claude Code sandbox, so that nobody cleans up by hand after a merge, while never touching work that is unmerged, uncommitted or in use.

## ADDED Requirements

### Requirement: Only the project's own linked worktrees are candidates
`coldlogic-prune-worktrees` SHALL consider only linked worktrees of the repository it runs in that lie under `<main>.worktrees/` or `<main>/.claude/worktrees/`, where `<main>` is the main checkout. It SHALL never remove the main checkout, a worktree elsewhere, or a locked worktree.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: A worktree outside the known locations
- **WHEN** a merged, clean, idle worktree lies at `/tmp/elsewhere`
- **THEN** it is left in place

#### Scenario: A locked worktree
- **WHEN** a merged, clean, idle worktree under `<main>.worktrees/` is locked with `git worktree lock`
- **THEN** it is left in place

#### Scenario: Run from a linked worktree
- **WHEN** the command runs from inside a linked worktree
- **THEN** it acts on the same repository's worktrees as when run from the main checkout, and never removes the main checkout

### Requirement: A dirty worktree is never removed
The command SHALL leave a worktree in place when it has staged, unstaged or untracked changes, an index entry marked skip-worktree or assume-unchanged, an ignored file that isn't regenerable or generated (`git worktree remove` deletes ignored files), or a rebase, merge, cherry-pick or revert in progress. It SHALL check without writing the worktree's index.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: An untracked file
- **WHEN** a merged, idle worktree has one untracked, non-ignored file
- **THEN** it is left in place

#### Scenario: A hidden change
- **WHEN** a merged, idle worktree has a tracked file marked skip-worktree or assume-unchanged, with a change `git status` doesn't show
- **THEN** it is left in place with the change

#### Scenario: A rebase in progress
- **WHEN** a merged, idle worktree has a clean tree but a rebase stopped partway
- **THEN** it is left in place

### Requirement: Only regenerable or generated ignored files may be lost
Ignored paths that SHALL NOT keep a worktree: at its top, `target`, `node_modules`, `.devenv.flake.nix`, `.mcp.json`, `.pre-commit-config.yaml`, `.claude/settings.json`, Nix's and OpenSpec's output (next requirement); at any depth, `.devenv`, `.direnv`, `__pycache__`, `.DS_Store`, and `devenv.lock` or `.devenv.flake.nix` beside a `devenv.nix`. Any other ignored file SHALL keep it, logged by name.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: Only regenerable or generated ignored files
- **WHEN** a merged, idle worktree's only ignored files are devenv's caches and bookkeeping in `.devenv/`, `node_modules/` and `target/` at its top, and `.claude/settings.json`, `.mcp.json`, `result` and `result-dev` links into `/nix/store/`, and OpenSpec's generated skill and command files
- **THEN** it is removed

#### Scenario: An ignored secrets file
- **WHEN** a merged, idle worktree has an ignored `.env`, `.dev.vars` or `devenv.local.nix`
- **THEN** it is left in place with the file, and the log names the file

#### Scenario: A nested build directory
- **WHEN** a merged, idle worktree has an ignored `sub/node_modules`, `sub/target` or `sub/result`
- **THEN** it is left in place

#### Scenario: A file inside a top-level pattern's directory
- **WHEN** a merged, idle worktree has an ignored `result-data/.dev.vars` or `.claude/skills/openspec-x/.dev.vars`, and neither directory is ignored as a whole
- **THEN** it is left in place, and the log names the file

#### Scenario: An unknown devenv-like name
- **WHEN** a merged, idle worktree has an ignored `.devenv.other`, or a `sub/.devenv.flake.nix` with no `sub/devenv.nix`
- **THEN** it is left in place, and the log names the file

### Requirement: Nix's and OpenSpec's output is known by its form
A top-level `result` or `result-*` SHALL count as regenerable only as a link into `/nix/store/`; `.claude/skills/openspec-*` only as a directory holding just a `SKILL.md` file, and `.claude/commands/opsx` only as a directory holding just `*.md` files, as `openspec init` writes them. Anything else by those names SHALL keep the worktree, logged by name.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: Not Nix's or OpenSpec's output
- **WHEN** a merged, idle worktree has a `result-2026-q3/` directory, a `result` file, a `result` link outside `/nix/store/`, a `.claude/commands/opsx` link, or a `.claude/skills/openspec-*` or `.claude/commands/opsx` directory holding another file
- **THEN** it is left in place, and the log names the path

### Requirement: A devenv service's data keeps its worktree
A `.devenv` directory SHALL keep its worktree when its `state` or `profiles/*/state` directory holds anything but devenv's own bookkeeping (`tasks.db` and its companion files, `files.json`, `prek`) and the module's stamps, since devenv services such as postgres keep their data there.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: A postgres cluster
- **WHEN** a merged, idle worktree has `.devenv/state/postgres` or `.devenv/profiles/developer/state/postgres`
- **THEN** it is left in place, and the log names that path

### Requirement: A worktree is removed only when its work is in main
The command SHALL treat a worktree's work as in main only when its HEAD is an ancestor of the default branch's remote-tracking ref (`origin/HEAD`'s target, else `origin/main`), or a pull request merged into the default branch has its branch as head branch and HEAD as, or an ancestor of, its head commit, or, with a detached HEAD, HEAD exactly as its head commit. A pull request merged into another branch SHALL NOT count.

Tested by: `packages/prune-worktrees-test.sh`, with a stub `gh-app`.

#### Scenario: Merged with a merge commit or fast-forward
- **WHEN** a clean, idle worktree's HEAD is an ancestor of `origin/main`
- **THEN** it is removed

#### Scenario: Squash-merged
- **WHEN** a clean, idle worktree's branch has a merged PR whose head commit is its HEAD, and HEAD is not an ancestor of `origin/main`
- **THEN** it is removed

#### Scenario: A commit after the merge
- **WHEN** a clean, idle worktree's branch has a merged PR, but HEAD has a commit the PR's head commit doesn't contain
- **THEN** it is left in place

#### Scenario: Unmerged commits
- **WHEN** a clean, idle worktree has commits that aren't in `origin/main` and no merged PR
- **THEN** it is left in place

#### Scenario: Detached and squash-merged
- **WHEN** a clean, idle worktree has a detached HEAD that is the head commit of a merged PR
- **THEN** it is removed

#### Scenario: Merged into another branch
- **WHEN** a clean, idle worktree's branch has a PR whose head commit is its HEAD, merged into `staging` rather than the default branch
- **THEN** it is left in place

#### Scenario: Another default branch
- **WHEN** `origin/HEAD` points at `origin/staging`, one clean, idle worktree's HEAD is an ancestor of `origin/staging`, and another's only of `origin/main`
- **THEN** the first is removed and the second is left in place

### Requirement: Without GitHub, only the git check is used
When `gh-app` is missing, fails or times out, the command SHALL decide with the ancestor check alone, keep any worktree that would need a pull request to count as merged, keep every branch without a worktree, and exit 0. The command SHALL NOT fetch: it uses the local remote-tracking ref, so it never contacts the git remote or asks for an SSH key.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: gh-app fails
- **WHEN** `gh-app` exits non-zero, and one worktree is squash-merged and another is an ancestor of `origin/main`
- **THEN** the squash-merged one is kept, the other is removed, and the command exits 0

### Requirement: One GitHub call per run
The command SHALL ask `gh-app` for merged pull requests at most once per run, with a timeout, only when a candidate needs one, and match them locally. When the answer has as many pull requests as the limit asked for, it SHALL log that, once until it changes.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: Several candidates need a PR
- **WHEN** two worktrees and two branches without a worktree each need a merged PR to count as merged
- **THEN** the command calls `gh-app` once

#### Scenario: The limit is reached
- **WHEN** two runs each get as many merged PRs as the limit
- **THEN** the log says so once

### Requirement: A worktree in use is never removed
The command SHALL leave in place the worktree that contains its own working directory or the session directory it is given (a relative one taken from where the run started), any worktree that a running process (of any user, as far as `lsof` sees) has as its working directory, checked again just before removing it, and any worktree with git or devenv activity within the idle period, 6 hours by default.

Tested by: `packages/prune-worktrees-test.sh`, with backdated activity times.

#### Scenario: The session's own worktree
- **WHEN** the command is given a session directory inside a merged, clean, idle worktree
- **THEN** that worktree is left in place

#### Scenario: A process works in it
- **WHEN** a running process has its working directory inside a merged, clean, idle worktree
- **THEN** that worktree is left in place

#### Scenario: A process starts in it during the run
- **WHEN** a process starts working inside a merged, clean, idle worktree after the run's first look but before its removal
- **THEN** that worktree is left in place

#### Scenario: Recently created
- **WHEN** a worktree was created from `origin/main` an hour ago and has no commits of its own
- **THEN** it is left in place

#### Scenario: Idle for longer than the period
- **WHEN** a merged, clean worktree's git and devenv activity is all older than the idle period, and no process uses it
- **THEN** it is removed

### Requirement: A worktree that changes during the run is kept
Just before removing a worktree, the command SHALL read its HEAD and its branch's tip again and run the clean check again, ignored files included, and SHALL leave it in place when either commit differs from what it checked or the check fails. The removal's log line and restore command SHALL name the commit read then.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: A commit during the run
- **WHEN** a commit is made in a merged, clean, idle worktree after its checks but before its removal
- **THEN** that worktree and its branch are left in place, and the log says why

#### Scenario: An ignored file written during the run
- **WHEN** an ignored `.dev.vars` is written into a merged, clean, idle worktree after its checks but before its removal
- **THEN** that worktree is left in place with the file, and the log names it

### Requirement: A worktree's abandoned commits keep it
The command SHALL leave in place a worktree, on a branch or detached, when its HEAD reflog has a commit that no ref and no merged PR's head holds, checked again just before removing it, or when that reflog can't be read, and log why: the reflog may be the only record of work abandoned there, and it goes with the worktree.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: A commit abandoned in a detached worktree
- **WHEN** a merged, clean, idle detached worktree had a commit, then was reset back to `origin/main`
- **THEN** it is left in place, and the log says its HEAD reflog has commits no branch holds

#### Scenario: A commit made detached, then back on the branch
- **WHEN** a merged, clean, idle worktree on a branch was detached, had a commit, and was switched back to its branch
- **THEN** it is left in place, and the log says its HEAD reflog has commits no branch holds

#### Scenario: Reset behind a merged PR's head
- **WHEN** a clean, idle worktree's branch was reset back from the head commit of its merged PR
- **THEN** it is removed: the PR holds the commit left in its HEAD reflog

#### Scenario: A commit abandoned during the run
- **WHEN** a commit is made and abandoned in a merged, clean, idle detached worktree after its checks but before its removal
- **THEN** it is left in place, and the log says why

### Requirement: Removal never forces
The command SHALL remove a worktree with `git worktree remove` without `--force`. When that fails, it SHALL leave what remains and go on to the next worktree. It SHALL then run `git worktree prune`, so a worktree whose directory is already gone is unregistered, but only when every such worktree lies under `<main>.worktrees/` or `<main>/.claude/worktrees/`; otherwise it SHALL skip it and log why.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: A half-deleted worktree
- **WHEN** a registered worktree under `<main>.worktrees/` has had its directory deleted
- **THEN** after a run, `git worktree list` no longer lists it

#### Scenario: A half-deleted worktree elsewhere
- **WHEN** a registered worktree at `/tmp/elsewhere` has had its directory deleted
- **THEN** after a run, `git worktree list` still lists it

#### Scenario: A locked half-deleted worktree
- **WHEN** a locked worktree under `<main>.worktrees/` has had its directory deleted
- **THEN** after a run, `git worktree list` still lists it, and the log doesn't call it unregistered

### Requirement: A missing volume isn't pruned
The command SHALL skip `git worktree prune`, and log why, when the root holding a worktree whose directory is gone, or that worktree's parent directory, does not exist as a directory, or the root is on another device than the main checkout, since a root linked to an unmounted volume makes its worktrees look deleted.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: An unmounted volume
- **WHEN** `<main>.worktrees` is a link to a volume that is no longer there, and a worktree under it is registered
- **THEN** after a run, `git worktree list` still lists it, and the log says why

#### Scenario: A root on another device
- **WHEN** `<main>.worktrees` is on another device than the main checkout, and a registered worktree under it has had its directory deleted
- **THEN** after a run, `git worktree list` still lists it, and the log says why

### Requirement: Pruning never loses a worktree's git state
The command SHALL count a worktree git calls prunable as gone only when nothing is at its registered path, and SHALL skip `git worktree prune`, and log why, when one is still there, or a gone one's admin dir in `.git/worktrees` has staged changes, a HEAD no branch, tag or remote branch holds, or a HEAD reflog commit no ref or merged PR's head holds, or can't be checked: a worktree moved by hand looks gone, and prune would delete its index.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: A worktree moved by hand
- **WHEN** a registered worktree with a staged change was moved by hand, or a detached one at an unheld commit, or one, on a branch or detached, with abandoned commits in its HEAD reflog
- **THEN** after a run, `git worktree list` still lists it, its admin dir and index survive, and the log says why

#### Scenario: Only its .git file is gone
- **WHEN** a registered worktree's `.git` file was deleted but its directory is still there
- **THEN** after a run, `git worktree list` still lists it and every other gone worktree, and the log says why

### Requirement: A removed worktree's branch goes with it
After removing a worktree, the command SHALL delete its local branch only when no other worktree (the main checkout included) holds it, read again then, it isn't long-lived, its name has no `]`, it still points at the checked commit, and it is the exact head of a PR merged into the default branch or has commits past `origin/HEAD`'s target that such a PR contains, with its config section. It SHALL never delete a remote branch.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: Branch and config removed
- **WHEN** a merged worktree on branch `fix/x`, the head of a merged PR, with a `branch.fix/x` config section, is removed
- **THEN** `fix/x` and its config section are gone, and `origin/fix/x`, if present, is untouched

#### Scenario: A worktree on the default branch
- **WHEN** a clean, idle worktree on `main`, at `origin/main`, is removed
- **THEN** `main` stays

#### Scenario: A worktree on a lagging branch
- **WHEN** a clean, idle worktree on `staging`, an ancestor of `origin/main` with no merged PR, is removed
- **THEN** `staging` stays, and the log says why

#### Scenario: A branch whose config section git can't address
- **WHEN** a branch named `feat]x`, the exact head of a merged PR, with a config section, has its worktree removed or has none
- **THEN** it stays with its config section, and the log says why

### Requirement: Long-lived branches are never deleted
The command SHALL never delete a long-lived branch, with or without a worktree, and SHALL log why it kept one. A branch is long-lived when it is the default branch, or is named, in any case, `main`, `master`, `develop`, `dev`, `staging`, `production`, `prod`, `release/*` or `hotfix/*`.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: A promoted staging branch
- **WHEN** branch `staging`, `develop`, `release/1.0` or `hotfix/x` is the exact head of a PR merged into the default branch, with or without a worktree
- **THEN** it stays, and the log says it is a long-lived branch's name

#### Scenario: A long-lived name in another case
- **WHEN** branch `Staging`, `Production` or `Release/1.0` is the exact head of a PR merged into the default branch
- **THEN** it stays, and the log says it is a long-lived branch's name

#### Scenario: A branch with an upstream
- **WHEN** a branch with `branch.<name>.merge` set, and no long-lived name, is the exact head of a merged PR, with or without a worktree
- **THEN** it is deleted with its config section, and the log has the command that restores it

### Requirement: Kept branches are logged
The command SHALL log why it keeps each local branch no worktree has checked out, the default branch and other long-lived ones included, and why it keeps a removed worktree's branch. A branch a worktree still has checked out SHALL get no line of its own: that worktree's line covers it.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: The default branch checked out nowhere
- **WHEN** the main checkout is on another branch and `main` is checked out nowhere
- **THEN** `main` stays, and the log says it's the default branch

### Requirement: Merged branches without a worktree are deleted
The command SHALL delete each local branch that no worktree has checked out (read again just before deleting it), that isn't long-lived, whose name has no `]`, that hasn't moved within the idle period, and that is, by name and tip commit, exactly the head of a pull request merged into the default branch, with its config section. Being an ancestor of main SHALL NOT be enough. Any other branch SHALL be kept.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: An orphaned merged branch
- **WHEN** branch `worktree-agent-x` has no worktree and its tip is the head commit of a PR from `worktree-agent-x` merged into the default branch
- **THEN** it is deleted

#### Scenario: A lagging branch
- **WHEN** branch `staging` has no worktree, hasn't moved for a day, and its tip is an ancestor of `origin/main`
- **THEN** it is kept

#### Scenario: Behind its merged PR
- **WHEN** a branch with no worktree has a merged PR whose head commit is past the branch's tip
- **THEN** it is kept

#### Scenario: An unmerged branch
- **WHEN** a branch with no worktree has a commit that isn't in `origin/main` and no merged PR
- **THEN** it is kept

#### Scenario: A branch just created
- **WHEN** a branch was created at `origin/main` ten minutes ago and no worktree has it
- **THEN** it is kept

#### Scenario: A worktree made on it during the run
- **WHEN** an orphaned merged branch gets a worktree after the run first reads the worktrees but before it deletes the branch
- **THEN** it is kept, and the log says another worktree has it checked out

### Requirement: A dry run changes nothing
With `--dry-run`, the command SHALL print each worktree and branch it would remove, a worktree's branch included when the real run would delete it with the worktree, and SHALL change no worktree, branch or config.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: Dry run
- **WHEN** the command runs with `--dry-run` and one worktree qualifies, its branch the head of a merged PR
- **THEN** it prints a `worktree` line with that worktree's path and branch and a `branch` line for the branch, and the worktree, branch and config are unchanged

### Requirement: Sessions prune in the background
The developer profile SHALL run the command from Claude Code `SessionStart` and `Stop` hooks (outside the Bash sandbox), passing the hook input's `cwd` as the session's directory. Each hook SHALL return at once, leaving the prune detached to outlive the session, print nothing, and exit 0 whatever the prune does. Within 10 minutes of the last run in `cwd`'s repository it SHALL start none, without running git when `cwd` is in the project dir.

Tested by: the session run in the change's tasks.

#### Scenario: A session starts after a merge
- **WHEN** a session starts in the main checkout and a worktree's PR merged more than the idle period ago
- **THEN** the session starts without waiting on the prune, shows no hook output, and the worktree and its branch are gone shortly after

#### Scenario: A long session
- **WHEN** a session has run for a day and a worktree it used merged and went idle meanwhile
- **THEN** after one of its turns ends, the worktree and its branch are gone shortly after, with no output in the session

#### Scenario: Nothing to remove
- **WHEN** a session starts and no worktree qualifies
- **THEN** nothing is shown and nothing changes

#### Scenario: Not a git repository
- **WHEN** a session starts in a directory that isn't in a git repository
- **THEN** the hook exits 0 and nothing is shown

#### Scenario: A hook whose cwd is in another repository
- **WHEN** the project dir's repository ran a prune just now, and a hook's `cwd` is in another repository
- **THEN** whether the hook starts a run depends on the other repository's last run

### Requirement: A terminal shell prunes in the background
Entering the shell outside a Claude Code session (`CLAUDECODE` unset) and outside CI (`CI` unset) SHALL start the command detached, without delaying the shell or failing it. Inside a session, the task SHALL do nothing.

Tested by: the terminal run in the change's tasks.

#### Scenario: Terminal shell
- **WHEN** Derek runs `devenv shell` from a terminal in a project with a merged, idle worktree
- **THEN** the shell starts as fast as before and the worktree is removed shortly after

#### Scenario: Shell inside a session
- **WHEN** a session runs `devenv shell --quiet -- true`
- **THEN** the task starts no prune

### Requirement: Runs are rate-limited and serialised
A background run (the hook's and the shell task's) SHALL be skipped when started within 10 minutes of the last background launch or completed run, and SHALL record its launch before it detaches. Every run SHALL be skipped while another holds the lock in the repository's git common dir. A lock left by a process that has exited SHALL NOT block later runs, only one run SHALL take over a stale lock, and a run SHALL never remove a lock it no longer owns.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: Two sessions start together
- **WHEN** two runs start at the same time for one repository
- **THEN** only one prunes, and the other exits 0 without changing anything

#### Scenario: A stale lock
- **WHEN** the lock names a process that has exited
- **THEN** the next run takes the lock and prunes

#### Scenario: A lock taken over mid-run
- **WHEN** another run replaces the lock while a run is working
- **THEN** the first run, on exit, leaves the new lock in place

#### Scenario: Sessions start while a run works
- **WHEN** a background run has launched and not finished, and another session starts
- **THEN** the second hook starts no run

### Requirement: A live run's lock is never taken over
A lock whose owner is still running SHALL never be taken over, however old. A lock whose recorded start time differs from that of the process now holding its pid SHALL be taken over: the pid was reused. A lock that names no owner SHALL be taken over only once it is over an hour old. A run skipped for a lock over an hour old SHALL log that, once until it changes.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: A slow run
- **WHEN** the lock is two hours old and its owner is still running
- **THEN** the next run exits 0 without changing anything, the lock stays, and the log says so once over two runs

#### Scenario: A reused pid
- **WHEN** the lock's pid is now a running process whose start time differs from the one the lock recorded
- **THEN** the next run takes the lock and prunes

#### Scenario: An ownerless lock
- **WHEN** the lock names no process and is two hours old
- **THEN** the next run takes it and prunes

### Requirement: A lock records its owner or is removed
A run SHALL record its owner in the lock it makes: its pid and its process start time, taken on Linux from `/proc/<pid>/stat` (field 22) and elsewhere from `ps -o lstart=`, tagged with its source. Start times SHALL be compared only when their sources match. When the owner can't be written, the run SHALL remove the lock again, log that once until it changes, and exit 0 without changing anything.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: A reused pid on Linux
- **WHEN** the lock's pid is a running process whose `/proc` start time differs from the one recorded
- **THEN** the next run takes the lock and prunes

#### Scenario: The owner can't be written
- **WHEN** two runs each make the lock but can't write their owner into it
- **THEN** each exits 0, the lock is gone, nothing is removed, and the log says why once

### Requirement: Removals are logged for good
Each run SHALL append to a log in the git common dir what it removed, with the commit and the command that restores it, its path and branch shell-quoted so it can be pasted, and why a candidate was kept when that differs from the last run, once per run. Trimming the log SHALL keep every removal.

Tested by: `packages/prune-worktrees-test.sh`.

#### Scenario: The same reason twice
- **WHEN** two runs keep the same branch for the same reason
- **THEN** the log has that reason once

#### Scenario: Kept twice in one run
- **WHEN** a run keeps a branch after removing its worktree, and again in its sweep of branches no worktree has
- **THEN** the log has that reason once

#### Scenario: Shell characters in a restore command
- **WHEN** a removed worktree's path has a space and its branch's name a `$( )`
- **THEN** the logged restore commands, pasted into a shell, restore both and run nothing else

#### Scenario: A long log
- **WHEN** the log has an old removal line and more than 1000 other lines
- **THEN** after a run, the removal line is still there and only the last 1000 other lines are

### Requirement: Prune tests gate its build
The command's test cases SHALL run against the script when its package builds, so the shell build, and so the gate, fails when a case fails. The tests SHALL need no network, session or `gh-app` credentials.

Tested by: the gate's shell build.

#### Scenario: A test case fails
- **WHEN** a change makes the prune remove a dirty worktree in its test
- **THEN** building the shell fails
