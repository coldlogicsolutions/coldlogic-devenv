# Tasks

Run the guard's cases with `devenv shell --quiet -- python3 -I packages/claude-guard-test.py`. It prints `N/N passed` and exits 0 when every case passes. A different decision from the one a task lists means the implementation differs from design.md: fix the code, not the expectation, or stop and ask.

## 1. Where a command runs (design decisions 1 and 2)

- [x] 1.1 In `packages/claude-guard.py`, add `repo_top(path)` (the first directory at or above `realpath(path)` with a `.git` entry), `main_checkout()` (from the project root: its top when `.git` is a directory, else through the `.git` file's gitdir and that gitdir's `commondir` to `<main>/.git`; `None` for no repository or a bare common dir) and `default_branch(main)` (`refs/remotes/origin/HEAD`, else `main`).
- [x] 1.2 Add `Unwrapped.moves` and `Unwrapped.moved`, merged in `add`. `unwrap` sets `moves` for `cd`, `pushd` and `popd`, and marks the command `env -C`/`--chdir` or `sudo -D`/`--chdir` runs. `analyse` marks each command that comes after a command that moved.
- [x] 1.3 Add `git_place(words, moved)`: the directory with each `-C` applied in turn (absolute replaces, relative joins, `~` expanded, an expansion or a moved start makes it unknown), the subcommand and its arguments.

## 2. The main-checkout check (design decisions 3 to 5)

- [x] 2.1 Add `leaves_branch(sub, args, default, here)` as design decision 3 describes, with option prefixes (`git_option`) and short clusters.
- [x] 2.2 Add `main_checkout_switch(result)` and call it in `decide` after the forbidden and secrets checks, inside the `try`. It denies with `MAIN_CHECKOUT` ("Branch work goes in a worktree: EnterWorktree, or isolation: \"worktree\" on a subagent (git.md).") first, asks when the directory is unknown, and does nothing when the cwd is unknown. Update the module docstring.
- [x] 2.3 Verify the existing cases all still pass.

## 3. #87 (design decision 6)

- [x] 3.1 In `git_waits_or_drops`, return true for `git worktree add` with `-B` in a cluster (`git_short(w, "B", "b")`) and for `git worktree remove` with `git_short(w, "f", "")` or `git_option(w, "--force")`. Update its docstring.
- [x] 3.2 Add BASH cases: `git worktree remove` with `-f`, `-ff`, a trailing `-f`, `--force`, `--forc` (before and after the path), `--fo`, `--f`, behind `devenv shell --` and in a chain ask; `git worktree add -B`, `-qB` and `--no-track -B` ask; `git worktree remove wt`, `git worktree add -b feat/x wt origin/main`, `--detach wt` and `-b B wt` stay allowed.

## 4. Tests for #88

- [x] 4.1 Add the block "The main checkout stays on main (#88)" to `claude-guard-test.py`: a temporary main checkout `proj` (with `sub/`, `README.md` and a nested `vendor/lib/.git`), linked worktrees `proj.worktrees/x` and `proj/.claude/worktrees/n`, and a repository `trunk` whose `origin/HEAD` names `trunk`. Policy: `POLICY` plus `git switch *` allowed and `git switch -f *` asked. Cases:
  - deny in the main checkout: every create form (`-c`, `-C`, `--create`, `--cr`, `--force-create`, `--fo`, `-qc`, `-cfeat/x`, `--orphan`, `checkout -b`, `-B`, `-qb`, `--orphan`, `--track`), every switch (`feat/x`, `-`, `-- feat/x`, `--detach`, `-d`, `--det`, `checkout feat/x`, a tag, a commit, `--detach`, `feat/x --`, a missing file); in chains, behind `devenv shell --` and `bash -c`, `-C .`, `-C <main>`, `--no-pager`, from a worktree with `-C <main>` or `-C ../../proj`, from a subdirectory, and before a `cd`;
  - not denied: `switch main` (allow), `--no-guess main` (allow), `-f main` (ask), `checkout main`, the file restores, `status`, `fetch`, `log`, `branch -vv`, a bare `git switch`, and the nested repository;
  - ask after a `cd` or through `env -C`; an absolute `-C` after a `cd` decides by where it points;
  - linked worktrees unchanged: `switch --no-track -c feat/x origin/main`, `-c`, `feat/x`, `--detach` allowed; `checkout -b`, `checkout v1.0` and `-C <worktree>` from the main checkout get no decision.
- [x] 4.2 Check the deny reason starts with `MAIN_CHECKOUT`; check a session rooted in the linked worktree (#65): `switch -c` in the worktree allowed, in the main checkout denied, `switch main` there asked as before; check `trunk`: `switch trunk` allowed, `switch main` denied.
- [x] 4.3 Add the #44 cases: a policy with `POLICY` plus the module's `git switch *` allow and its six `git switch` ask rules from `devenv.nix`; in `proj.worktrees/x` and `proj/.claude/worktrees/n`, with the session rooted in the main checkout, and in `proj.worktrees/x` rooted there. `git switch --no-track -c feat/x origin/main`, `--no-track -c fix/guard-y origin/main`, `-c feat/x`, `-c feat/x origin/main`, `--create`, `--no-track --create`, `-c feat/x --no-track origin/main`, behind `devenv shell --quiet --`, after `git fetch origin main &&`, `git switch feat/x`, `git switch -`, `--track -c` and `-C` allow; `-f`, `-fc`, `--discard-changes` and a trailing `-f` ask.
- [x] 4.4 Verify the whole file passes.

## 5. Docs and gate

- [x] 5.1 In `README.md`, in the `packages/claude-guard.py` row, add the main-checkout deny, the file restores it leaves alone, the ask after a `cd`, and the #87 asks.
- [x] 5.2 Run `devenv shell --quiet -- openspec validate guard-main-checkout-on-main --strict` and verify it reports the change valid.
- [x] 5.3 Run the gate, `devenv shell --quiet -- scripts/check.sh`, and verify it passes.

## 5b. Review fixes (design decisions 1 to 5)

- [x] 5b.1 In `decide`, return the main-checkout deny at once, and its ask only after the deny rules, the shell-edit deny and the gate's denies; `main_checkout_switch` returns a deny for any command before an ask for another.
- [x] 5b.2 Carry `env -C`/`sudo -D` into what they run: `bash -c`/`eval`, `env -S`, `find -exec` and a runner's `-c` (`moved_by`).
- [x] 5b.3 Follow a literal `cd`/`pushd` (`cd_target`, `moved_to`); restore at a subshell's `)`; a cd in a pipeline or backgrounded, and substitutions after a cd, are unknown. `Unwrapped.moved` maps ids to start directories.
- [x] 5b.4 `normalize_git` remembers the `-C` it drops (`GitWords.dropped_dir`), which `git_place` applies first; `git_place` uses `GIT_VALUE_FLAGS`/`GIT_FLAGS`, and `GIT_SPLIT_VALUED` goes.
- [x] 5b.5 `leaves_branch` treats `HEAD` and `@` as no change, and a single operand that is a path and a ref (`names_ref`, loose or packed) as the ref.
- [x] 5b.6 `linked_git_dirs` is shared by `main_checkout` and `own_worktree`; `default_branch` falls back to an existing `main`, then `master`, loose or packed, then `main`.
- [x] 5b.7 Cases for each in the "main checkout stays on main" block: literal and unreadable cds, subshells, pipes, `&`, `{ }`, `env -C`/`sudo -D` through `bash -c`, `sh -c`, `env -S`, `find -exec` and `npx -c`, a deny winning over the ask (deny rule, gate pipe, force push), `-C <cwd>` after a cd, paths that are refs (loose branch, packed branch, loose and packed remote branch, packed tag), `HEAD` and `@`, and repositories with `master`, loose and packed, or neither. Update the spec, design and README; run the gate.

## 6. Integration check (needs Derek: a fresh session)

- [ ] 6.1 (Manual, after merge.) Derek enters `devenv shell` once from a terminal in the main checkout so the guard hook updates, then starts a fresh Claude Code session there. In it, `git switch -c probe/main-guard` must be denied with the worktree message, and `git switch main` must run. Then `EnterWorktree` (or a subagent with `isolation: "worktree"`) must still run `git switch --no-track -c probe/main-guard origin/main` without a prompt. Remove the probe branch afterwards.

## Workflow follow-up

- Open the PR with `Closes #44`, `Closes #87`, `Closes #88` and `Refs #65`.
