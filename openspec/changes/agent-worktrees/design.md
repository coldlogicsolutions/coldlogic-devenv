# Design

## Context

See proposal.md for the motivation. These are the facts the approach rests on, checked on 2026-11-11.

- **Where agent worktrees land.** Claude Code's default is `<project>/.claude/worktrees/<name>`. Derek's user-level `WorktreeCreate` hook (`~/.claude/hooks/worktree-create.sh`, not in this repo) replaces it with `<main checkout>.worktrees/<name>`, where `<main checkout>` is `dirname(git rev-parse --git-common-dir)`. So `isolation: worktree` agents run in `/Users/derekjw/Projects/coldlogic-devenv.worktrees/agent-*`. The `.claude/worktrees/*` checkouts that exist are older `EnterWorktree` worktrees from before the hook. Both layouts must work, and the module can't assume the hook, since adopting projects may not have it.
- **A sibling worktree's git layout** (`agent-ab2b51e6540ed40e1`): its `.git` file reads `gitdir: <main>/.git/worktrees/agent-ab2b51e6540ed40e1`. That directory's `gitdir` names `<worktree>/.git` back, and its `commondir` is `../..`. It also has a `config.worktree` holding `core.hooksPath` (`extensions.worktreeConfig` is on). So git there reads the project's own config, plus a per-worktree file inside the project's `.git`.
- **What the guard sees.** In a subagent, `CLAUDE_PROJECT_DIR` is the main checkout and the hook event's `cwd` is the worktree. Running the guard with those values reproduces #42 and #44: `git status`, `git log`, `git add` and `git switch -c` all come back `ask` ("an allow rule names git, but not with these arguments"). They aren't deferred, as #42 assumed. Two things combine. `away_from_root()` is true, so no plain-command allow is tried. Then `plain_args()` counts every bare word (`status`) as a path outside the project, since `resolve()` knows only the project root. `git -C <path>` returns no decision anywhere unless the path is `.`. In the main checkout, all of these are already allowed.
- **The sandbox.** It is configured from the main checkout's generated settings. A worktree's own generated settings aren't loaded. The main checkout's allowWrite has the project root and `.`, but not `<main>.worktrees`. devenv's runtime dir is `/tmp/devenv-<first 7 hex of sha256(<checkout>/.devenv/profiles/<profile>)>`, under `/tmp`, not `$TMPDIR`. The main checkout's is `/tmp/devenv-5a969cc`. A new worktree gets a new hash.
- `own_worktree()` already checks the `.git` file and the back-pointer, but `at_top()` only calls it for paths under the root. `project_file()` already counts the cwd as part of the project for a session in a sibling worktree.

## Goals / Non-Goals

**Goals:**
- A subagent in either worktree layout gets the same guard decisions as a session in the main checkout, for commands and for file tools.
- `devenv shell`, the gate, `gh-app` and `git commit` work from inside a subagent's sibling worktree under the sandbox, including the first shell in a fresh worktree.
- Nothing is widened beyond the project's own worktrees, except devenv's runtime dirs (see Risks).

**Non-Goals:**
- `.git/config` writes (upstream tracking from `git switch -c x origin/main`, `git worktree add -b … origin/main`, `git push -u`). The sandbox keeps protecting `.git/config`. The existing convention is `--no-track` and `--detach`, then `git push origin <branch>` without `-u`.
- Changing where worktrees are created. That's the user's hook, outside this repo.
- Adding `permissions.additionalDirectories`. The Edit allow rule and the guard's allow cover the prompts that were seen. Revisit if Read or Grep prompts show up in sibling worktrees.
- Guarding against a session that forges worktree metadata on purpose. The guard catches mistakes, not attackers.

## Decisions

### 1. One notion of "the checkout a path is in"

Add `checkout_of(path)` to `claude-guard.py`. Take `realpath(path)` and walk up from it. Return the project root when the walk reaches it. Return a directory when it is the first one on the way that has a `.git` entry and `own_worktree(dir, root)` holds. Return `None` when the first `.git` on the way belongs to anything else (a nested repo, another repo's worktree, a look-alike), or when the walk reaches `/`. Then:

- `away_from_root()` returns `checkout_of(cwd) is None`. It keeps its early `False` when cwd or root is unknown.
- `at_top()` returns `checkout_of(cwd) == realpath(cwd)`. It keeps its early `True` when cwd or root is unknown. So a relative program, such as `scripts/check.sh`, is still only trusted at a checkout's top, as now.
- `own_worktree(here, base)` also requires `<gitdir>/commondir` to exist and to resolve, relative to the gitdir, to `realpath(<base>/.git)`. It drops nothing it checks today. It no longer has to be under the root, because the `.git`, gitdir and back-pointer checks already tie it to the project's repository.

*Why:* the existing reason for deferring away from the root is that git might find another repository's config. A linked worktree whose `commondir` is the project's `.git` reads the same config, so that reason doesn't apply. Its `config.worktree` lives in the project's `.git`, like the root's own config. Stopping at the first `.git` keeps the nested-repository protection (`vendor/lib/.git` inside a worktree still defers).

*Alternatives:* (a) Rebase `WORKING["root"]` onto the worktree in `main()`. Rejected: the main checkout's `.claude` would then count as outside, and its edits would stop asking. (b) Trust any directory under `<main>.worktrees/`. Rejected: that is location-based, and a stray clone there would pass.

### 2. Paths resolve against the checkout they are in

`resolve(path)` keeps returning the part relative to the project root for paths inside it. Behaviour inside the root is unchanged, so `.claude/worktrees/<n>/…` still resolves root-relative and `claude_config()`'s existing skip still applies. For a path outside the root, it returns the part relative to `checkout_of(resolved)` when that is one of the project's worktrees, else `None`. As a result:

- `plain_args()`/`outside()`: a relative argument in a sibling worktree counts as inside. Absolute paths and `..` stay outside by their text, as now.
- `secret_path()`: names are judged relative to the worktree, like the root.
- `claude_config()`: `<sibling>/.claude/...` asks, from any cwd. That matches the existing rule that a `.claude` inside a worktree asks.
- `project_file()`: its second base becomes `checkout_of(cwd)` when that isn't `None`, else cwd as now. So `echo x > ../src/b.rs` from `<sibling>/packages` is still turned to Edit/Write.

### 3. `git -C` naming one of the project's checkouts

In `normalize_git()`, a `-C` value other than `.`/`./` is dropped (as `.` is today) when all of these hold: the command runs at a checkout top (`at_top()` and cwd known), and the value, taken relative to cwd, resolves to the project root or to a directory `d` with `checkout_of(d) == d`. Otherwise the words are returned unchanged, as now.

*Why at a top only:* relative arguments after `-C` are git-relative to the `-C` directory, but the guard resolves them from the cwd. When both are tops of checkouts of the same repository, an inside path stays inside. From a subdirectory, the two could differ, and the narrow case covers what agents do. `normalize_git` is used by both `analyse()` and `simple_command()`, so the two readings still agree. Deny and ask matching already drop `-C` (`normalize_git_loosely`), so nothing forbidden gets through.

### 4. Sandbox and Edit rule cover `<main checkout>.worktrees`

In `devenv.nix`'s developer module, add a `mainCheckout` binding. When `${config.devenv.root}/.git` is a regular file whose content matches `gitdir: <M>/.git/worktrees/<name>`, it is `<M>`. Otherwise it is `config.devenv.root`. devenv evaluates impurely, so it can read the file:

```nix
mainCheckout =
  let
    dotGit = "${config.devenv.root}/.git";
    linked =
      if builtins.pathExists dotGit && builtins.readFileType dotGit == "regular" then
        builtins.match "gitdir: (.*)/\\.git/worktrees/[^/]+[[:space:]]*" (builtins.readFile dotGit)
      else
        null;
  in
  if linked == null then config.devenv.root else builtins.head linked;
siblingWorktrees = "${mainCheckout}.worktrees";
```

- `rules.Edit.allow` gains `"/${siblingWorktrees}/**"`.
- `sandbox.filesystem.allowWrite` gains `siblingWorktrees`.

*Why the main checkout:* a session opened in a worktree spawns agents into `<main>.worktrees`, not `<worktree>.worktrees` (the hook uses the common dir).

*Alternative:* point the hook at `.claude/worktrees`, which is already writable. Rejected here because the hook belongs to the user, and the layout it chose is the one in use. Both layouts keep working.

### 5. devenv's runtime dirs

`sandbox.filesystem.allowWrite` gains `/tmp/devenv-*` and `/private/tmp/devenv-*` (`/tmp` is a symlink on macOS). *Why a glob:* the hash comes from each checkout's path, and agent worktree names are random, so the names can't be listed at eval time. `config.devenv.runtime` gives only the main checkout's.

*Alternatives:* (a) `XDG_RUNTIME_DIR=$TMPDIR`, as README already suggests for `scripts/adopt.sh`. Rejected for sessions. The prefix defeats the guard's `devenv shell --` unwrapping, so every command would prompt. A session's shell would also use a different runtime dir from a terminal's, so `devenv up` processes started outside wouldn't be found. (b) Set it once in `claude.code.env`. Rejected: `$TMPDIR` is per session and can't be written there statically.

## Risks / Trade-offs

**Security trade-offs (flagged for review):**

- **[Wider guard allow]** Plain allowed commands (`git status/log/diff/add/commit/switch/branch/worktree`, `gh-app pr …`, `openspec`, `scripts/check.sh` at the top) now auto-allow in any linked worktree of the project's repository, wherever it sits, not only under `.claude/worktrees`. → The checks are the `.git` file, the back-pointer and `commondir`, so it can't be another repository. A relative program at a worktree's top is that branch's file, as it already is for `.claude/worktrees`.
- **[Forged worktree metadata]** A sandboxed command can write `.git/worktrees/<n>/` (`git worktree add --detach` works from a session), so it could fabricate an entry that names any directory back. → That is deliberate forgery, not a mistake, and out of scope for a mistake-catcher. Git would then really treat that directory as a worktree of the project, so the guard's reading would still be accurate.
- **[Per-worktree config]** git in a worktree also reads `.git/worktrees/<n>/config.worktree`, and the sandbox can write it (the `coldlogic:worktree-hooks-path` task does). A command could set a pager or an fsmonitor there, which an allowed `git log` would then run. → The same is true of the root checkout's `.git/config.worktree` today. File tools deny any `.git` path. Not widened in kind.
- **[Sandbox write to all sibling worktrees]** allowWrite of `<main>.worktrees` lets any sandboxed command write every one of this project's sibling worktrees, not only the agent's own. One agent could clobber another's work. → The same holds within the main checkout today. Everything there is under git. Only this project's directory is opened, and other projects' `.worktrees` stay closed.
- **[Runtime dirs beyond this repo]** `/tmp/devenv-*` is every devenv project's runtime dir on the machine, not just this repo's. They hold process sockets and temporary files, and a sandboxed command could delete or replace another project's. This is the one place the change reaches beyond this repo's own worktrees. → Connecting to those sockets still needs `network.allowUnixSockets`, which this doesn't widen. No project data lives there: devenv state is in `.devenv/state`. **Derek to confirm** (see Open Questions).

**Other risks:**

- **[Glob support]** Whether the sandbox's allowWrite honours a `*` glob, and whether it covers paths below the match, is unverified. Deny lists in the same settings already use `**`. On Linux, Claude Code's sandbox may not support globs. → Task 6.2 checks it in a fresh session. If a glob isn't honoured, `/private/tmp/devenv-*/**` is the next form to try. If neither works, drop decision 5 and keep #45's `/tmp` item open.
- **[Eval reads `.git`]** `builtins.readFileType` needs Nix 2.14 or later, which devenv 2.4's Nix has. A `.git` file in an unexpected format falls back to `config.devenv.root`, which is today's behaviour.
- **[Agent cwd assumption]** The fix assumes a subagent's Bash `cwd` is its worktree or the main checkout. Decision 3 covers both. A cwd somewhere else would still prompt, as today.

## Migration Plan

Projects get it on their next module update. Nothing to migrate. Rollback is reverting the commit. Settings regenerate when the shell is next entered from a terminal (a session can't relink its own settings).

## Open Questions

- **Derek:** is opening `/tmp/devenv-*` (every devenv project's runtime dir) acceptable? If not, decision 5 and tasks 4.3 and 6.2's runtime check drop out. A fresh worktree's first `devenv shell` then still has to be entered from a terminal (#45 stays open for that item). Nothing else in the plan changes.
