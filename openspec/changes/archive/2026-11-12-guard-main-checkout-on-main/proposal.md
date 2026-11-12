# Proposal

## Why

Derek decided (#88) that the project's main checkout always stays on `main`. All branch work, trivial work included, goes in a harness worktree: `EnterWorktree` in the main session, or `isolation: "worktree"` on a subagent. A trivial change can turn out not to be trivial, and parallel work can need to start at any time. Both are easier when the main checkout is on `main`. The guidance lives in claude-plugins-coldlogic's `git.md` and `process.md`. Enforcement belongs in the guard hook.

The guard also has two mistake-level holes in `git worktree` (#87). `git worktree remove -f`, or a prefix of `--force` such as `--fo`, isn't caught: the ask rules list only the full spellings, so `git worktree *` allows a forced removal of a dirty worktree. `git worktree add -B`, alone or in a cluster such as `-qB`, resets an existing branch and is allowed the same way.

#44 asked that creating and switching branches never prompt, while the forced forms still ask. Derek's note on it: switching branches belongs only in worktrees. So, folded in here: inside a linked worktree, `git switch --no-track -c <type>/<name> origin/main` (and `-c`/`--create` with no tracking) is allowed without a prompt under the module's own `git switch` rules, and the main checkout's side is the deny above.

## What Changes

- In the project's main checkout, the guard denies a `git switch` or `git checkout` that would take it off the default branch: creating a branch (`switch -c`/`-C`/`--create`/`--force-create`/`--orphan`, `checkout -b`/`-B`/`--orphan`), detaching (`--detach`, `-d`), or checking out any other branch, commit or tag. The deny reads: "Branch work goes in a worktree: EnterWorktree, or isolation: \"worktree\" on a subagent (git.md)."
- It still allows `git switch main` and `git checkout main`, file restores (`git checkout -- <paths>`, `git checkout <rev> -- <paths>`, a tree-ish and paths, `-p`, a single operand that names an existing path or a glob), and everything else, read-only commands and `git fetch` included.
- The check applies to every command of a call, behind wrappers, in chains and in `bash -c`. It reads git's global options, `-C` included (applied in turn, as git does), and git's option prefixes and short clusters. After a `cd` (or `env -C`, `sudo -D`), where the checkout can't be told, a branch-changing command asks instead. An absolute `-C` still says where it runs.
- Main checkout versus linked worktree: the guard walks up from the directory the command runs in to the first `.git`, and compares that top with the project's main checkout. The main checkout is found from the project root. When the session itself starts in a linked worktree (#65), the guard follows its `.git` file and `commondir` to `<main>/.git`.
- Inside a linked worktree (under `<checkout>.worktrees/`, `<checkout>/.claude/worktrees/` or anywhere else) and in a nested repository, behaviour is unchanged.
- `git worktree add -B` (also in a cluster, `-qB`) and `git worktree remove` with `-f` or any prefix git accepts of `--force` get no allow, so the `git worktree *` allow rule makes the guard ask (#87).
- #44: in a linked worktree, `git switch -c|--create <type>/<name> [start]`, with `--no-track` or no tracking, behind `devenv shell --` or after `git fetch ... &&`, is allowed with no prompt under `devenv.nix`'s `git switch *` allow and its ask rules. `git switch <branch>` and `git switch -` are too. `--track` and `-C` behave as before (allowed); `-f`, `-fc`, `--discard-changes` still ask. The guard already gave this; the change pins it with tests against the module's rules.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `claude-guard`: denies branch switches in the main checkout, allows creating an untracked branch in a linked worktree with no prompt, and asks for a forced `worktree remove` and `worktree add -B` in every spelling.

## Impact

- `packages/claude-guard.py`: new `main_checkout_switch` and helpers (`repo_top`, `main_checkout`, `default_branch`, `git_place`, `leaves_branch`), called from `decide`. `Unwrapped` records where a `cd` comes before a command. `git_waits_or_drops` covers `worktree add -B` and a forced `worktree remove`.
- `packages/claude-guard-test.py`: a block for the main checkout on main, with a temporary main checkout, linked worktrees in both places, a nested repository, a session rooted in a linked worktree, and a repository whose `origin/HEAD` is `trunk`; and cases for #87.
- `README.md`: the guard row.
- `devenv.nix`: no change. `git switch *` stays allowed; the guard denies the main-checkout forms before that rule applies.
- `packages/claude-guard-test.py` also gets #44 cases: the module's `git switch` allow and ask rules, in both kinds of linked worktree, with the session rooted in the main checkout or in the worktree.
- #44: in the main checkout, `git switch -c` becomes a deny. In linked worktrees it runs without a prompt.
- Closes #44, #87 and #88. Refs #65.
