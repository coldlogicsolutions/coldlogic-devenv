# Design

## Context

See proposal.md for the motivation. The facts the approach rests on, checked on 2026-11-12:

- **How the guard knows checkouts.** `checkout_of(path)` walks up from a path to the first `.git` and accepts the project root or one of its own worktrees (`own_worktree`). It works from `WORKING["root"]` (`CLAUDE_PROJECT_DIR`). When the session starts in a linked worktree, that root is the worktree, and the main checkout counts as "away" (#65). So `checkout_of` can't be reused as is to name the main checkout.
- **What the guard sees of a git command.** `analyse` gives each command unwrapped (`devenv shell --`, `bash -c`, `env`, `timeout`...), with git's global options normalised by `normalize_git`. A single `-C` naming the cwd at a checkout's top is dropped, and any other `-C` stays in the words. `-c`, `--git-dir`, `--work-tree` and the like raise `Unparsable`, so such a call asks before any of this runs.
- **cd.** `unwrap` marks a `cd`, `pushd` or `popd` as opaque and drops it. Later commands in the call keep no record that they run somewhere else.
- **git's parsing.** git takes any unique prefix of a long option (`git_option` counts every prefix of three or more characters), and short options in clusters, where an option taking a value takes the rest of the word (`git_short`). `git checkout <x>` without `--` is a branch switch when `<x>` is a revision, and a file restore when it is only a path. With two or more operands, the first is a tree-ish and the rest are paths. `checkout <x> --` with nothing after the `--` switches to `<x>`. `git switch` takes no paths.
- `devenv.nix` allows `git switch *` and asks for its forced forms. `git checkout` has no allow rule. `git worktree *` is allowed, and its forced remove asks only in the four full spellings.

## Goals / Non-Goals

**Goals:**
- In the main checkout, any `git switch` or `git checkout` that would leave the default branch is denied, in every spelling the guard can read, in any part of a call.
- `git switch main`, `git checkout main`, file restores and all read-only commands are untouched.
- Linked worktrees, wherever they sit, and nested repositories behave exactly as before.
- #87: `worktree add -B` and a forced `worktree remove` in any spelling ask.
- #44: in a linked worktree, `git switch --no-track -c <type>/<name> origin/main` and the other untracked create forms, `git switch <branch>` and `git switch -` get the allow under the module's own rules, with no prompt; the forced forms ask. The existing `git switch *` allow and the guard's worktree handling already give this, so no code changes for it; the tests pin it with the module's actual ask rules.

**Non-Goals:**
- Other ways to move a checkout's HEAD: `git stash branch`, `git rebase`, `git reset`, `git bisect`, an alias (`git co`), `git -c alias.x=...` (already asks), `xargs git switch` (the branch comes from stdin). See Risks.
- Fixing #65 for the rest of the guard (`own_worktree`, `checkout_of`). Only the main-checkout check reads the `.git` file.
- Allowing `git pull --ff-only` or `git worktree add` paths (#84's dropped parts).
- Guarding other repositories' main checkouts. The check is for this project's.

## Decisions

### 1. Main checkout versus linked worktree, from the files git reads

`repo_top(path)` walks up from `realpath(path)` to the first directory with a `.git` entry: the top of the working tree git would use there. `main_checkout()` starts from the project root (or the cwd). If its top's `.git` is a directory, that top is the main checkout. If it is a file (a linked worktree, the #65 case), the guard reads `gitdir:` (relative to the worktree), then that gitdir's `commondir` (relative to the gitdir). If the result is a directory named `.git`, its parent is the main checkout. Anything else (no repository, a bare common dir) means there is no main checkout, and the check does nothing.

`linked_git_dirs(top)` reads a linked worktree's `.git` file and its gitdir's `commondir`. `main_checkout()` and `own_worktree()` share it.

A command is in the main checkout when `repo_top(<the directory it runs in>) == main_checkout()`. A linked worktree has its own `.git` file, so its top is never the main checkout, wherever it sits. A nested repository has its own `.git`, so it isn't either.

*Why not `git rev-parse --git-dir` against `--git-common-dir`:* the guard never runs git. Running it would read the repository's config (an fsmonitor, a hook path), which is what the guard keeps commands from doing unchecked. The two files git itself reads give the same answer.

*Why not `checkout_of`:* it answers a different question (is this one of the project's checkouts, for allows) and is keyed on the session's root, which may be a linked worktree.

### 2. The directory a command runs in

`git_place(words, start)` starts from where the command starts and applies each `-C` in turn, as git does: an absolute value replaces the directory, a relative one is joined to it. `~` is expanded. A `-C` holding an expansion makes the directory unknown. `normalize_git` drops a `-C` naming the cwd before rules match; it now remembers it (`GitWords.dropped_dir`), and `git_place` applies it first, so after a cd it still says where the command runs. Only `-C`, `--no-pager` and `--no-optional-locks` are left by then (`GIT_VALUE_FLAGS`, `GIT_FLAGS`; the rest raise `Unparsable`); any other option makes the directory unknown.

`analyse` follows `cd` and `pushd` in order (`Unwrapped.moved` maps each command's id to its start directory, None when unknown). A literal target (`cd_target`: one operand, `~` for a bare `cd`) that exists is joined to where the call is (`moved_to`). It is unknown when it holds an expansion or glob, is relative from an unknown place or one `CDPATH` may resolve, doesn't exist (the cd fails, and after `;` the next command runs where it was), or is `cd -`, `popd`, `pushd +N` or a bare `pushd`. A cd in a `(...)` subshell ends at its `)`: `analyse` saves where each depth was entered and restores it. A cd in a pipeline stage or backgrounded makes the place unknown. Commands in substitutions after a cd are unknown. `env -C`/`--chdir` and `sudo -D`/`--chdir` mark the commands they run as unknown, through `bash -c`, `eval`, `env -S`, `find -exec` and a runner's `-c` too (`moved_by`). Only an absolute `-C` makes an unknown place known again.

*Why the order matters:* `git switch -c x && cd sub` runs the switch in the cwd and should be denied. `cd <main> && git switch -c x` from a worktree is exactly the mistake to catch.

*Why not make a cd allowable:* a cd is still opaque for allows: `plain_args` reads every other command's paths from the cwd, and re-rooting them is a wider change. `cd packages/foo && git switch ...` in a worktree is left to Claude Code's rules, as before, rather than asked.

### 3. What leaves the default branch

`leaves_branch(sub, args, default, here)` reads the arguments once, left to right:

- A create option: for `switch`, any short cluster holding `c` or `C` and any prefix of `--create`, `--force-create` or `--orphan`; for `checkout`, `b`, `B` and `--orphan`. Returns "creates a branch".
- `-d` in a cluster, or a prefix of `--detach`. Returns "detaches HEAD".
- `checkout -p`/`--patch` or `--pathspec-from-file`: a file restore.
- Long options that take the next word (`--conflict`, the create options, `--pathspec-from-file`) skip it, unless given with `=`.
- For `checkout`, a `--` starts paths. For `switch`, words after `--` are still its branch.

Then:

- Paths after `--`, `-p` or a pathspec file: a file restore, not a switch.
- No operand, or the first operand is the default branch, `HEAD` or `@`: no change.
- `checkout` without `--`: two or more operands are a tree-ish and paths, a restore. One operand is a restore when it holds a glob character, or names an existing path from where the command runs and no ref (`names_ref`): git prefers the ref. Otherwise it is a branch, commit or tag.
- Anything else: "checks out `<x>`".

`names_ref(gitdir, name)` reads the main checkout's `.git`, loose files and `packed-refs`: `refs/<name>`, `refs/tags/`, `refs/heads/`, `refs/remotes/<name>` and its `HEAD`, an upper-case pseudo-ref, and `refs/remotes/*/<name>`, which `checkout` would make a branch from.

The default branch is what `<main>/.git/refs/remotes/origin/HEAD` names. Symbolic refs aren't packed, so the file is the place to read it. With no `origin/HEAD`, it is `main` or `master`, whichever exists as a branch (loose or packed, `main` first), else `main`.

Prefixes count as git's would. An ambiguous prefix (`--c`, `--fo` for switch) makes git fail, so denying it costs nothing.

### 4. File restores

`git checkout -- <paths>` and `git checkout <rev> -- <paths>` change files, not the branch. A file restore in the main checkout is something a session might need to undo its own stray edit, so they stay allowed (they still get no allow from the guard, as before, since `git checkout` has no allow rule). The ambiguous single-operand form is judged as git judges it, as far as the guard can: an existing path is a restore. A file that no longer exists in the working tree (`git checkout deleted.txt`) is denied as a checkout. The deny message then says to use `git checkout -- <path>` or `git restore`.

### 5. Where it runs, and what it returns

`main_checkout_switch(result)` runs in `decide` right after the forbidden and secrets checks, over every command of the call (`result.commands`, which holds every unwrapped command, `bash -c` and substitutions included). A call to a shell function the call defines is skipped, as the forbidden check skips it. The check does nothing when the cwd is unknown, which keeps every existing case unchanged.

- In the main checkout: `deny`, with the message from #88 first, then which form was found and the default branch. A deny for any command of the call beats an ask for another.
- Directory unknown (decision 2): `ask`, saying the guard can't tell which checkout it runs in, with the same pointer to a worktree. The ask waits until the deny rules, the shell-edit deny and the gate's denies have run: a deny always wins.
- Anywhere else: no decision from this check. The rest of `decide` runs as before.

### 6. #87: forced remove and `add -B`

`git_waits_or_drops` (used by `plain_args`) now also returns true for `git worktree add` with `B` in a short cluster before any `b` (whose value takes the rest of the word), and for `git worktree remove` with `f` in a cluster or any prefix of `--force` from `--f`. Such a command gets no allow, and since `git worktree *` names it, the guard asks ("an allow rule names git, but not with these arguments").

## Risks / Trade-offs

- **[Other ways off main]** `git stash branch`, `git rebase`, `git reset <rev>`, `git bisect`, aliases and `xargs git switch` aren't caught. → The guard catches the common mistake (switching or creating a branch); the guidance in `git.md` covers the rest. They can be added if they show up.
- **[cd asks]** A cd the guard can't follow (`cd "$D"`, `cd -`, `popd`, a missing directory, a cd in a pipeline) makes a later branch switch ask, even inside a linked worktree. → Rare, since the conventions say to run `cd` as its own call. A literal cd, or an absolute `-C`, avoids it.
- **[cd still gets no allow]** `cd packages/foo && git switch --no-track -c x origin/main` in a worktree isn't asked by this check, but a cd still rules out the guard's allow, so Claude Code's own rules decide it, as before this change. → Run the cd as its own call, or use `git -C`.
- **[CDPATH]** A relative cd target is followed only when `CDPATH` is unset in the hook's environment, or the target starts with `.`; the session's shell could still set its own. → Rare; it would at worst judge the switch from the wrong directory.
- **[Deleted-file restore]** `git checkout deleted.txt` in the main checkout is denied as a checkout. → The message names `git checkout -- <path>` and `git restore`.
- **[A path named like a branch]** `git checkout docs`, with a `docs/` directory and a `docs` branch, tag or remote branch, is denied: git checks out the ref. `git checkout -- docs` restores it. A commit id that is also a path name isn't read as a ref, so it counts as a restore.
- **[Look-alike layouts]** The check reads `.git` files as git does, but doesn't verify a linked worktree's back-pointer. A directory with a forged `.git` file inside the main checkout would count as a worktree. → Forgery, not a mistake (as for `own_worktree`).
- **[Default branch]** A repository with no `origin/HEAD` falls back to `main` or `master`, whichever exists, else `main`. One whose default is another name and has no `origin/HEAD` would have `git switch <default>` denied. → `git remote set-head origin -a` writes it. All coldlogic repositories use `main`.
- **[Session started in a linked worktree]** The main checkout is now found through the worktree's `.git` file. Elsewhere the guard still treats the main checkout as away from the root (#65 stays open), so `git switch main` there asks rather than allows.

## Migration Plan

Projects get it on their next module update. Nothing to migrate. A session already on a branch in the main checkout can still `git switch main`. Rollback is reverting the commit.

## Open Questions

None.
