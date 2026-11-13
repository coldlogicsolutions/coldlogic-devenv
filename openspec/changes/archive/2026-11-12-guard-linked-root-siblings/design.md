# Design

## Context

See proposal.md for the motivation. What the approach rests on is below. "Checked" means read in the code on this branch, or run on 2026-11-12 with the planned `checkout_of` patched onto the guard in memory (no file changed). "Assumed" is marked as such.

Checked:

- **One function decides.** `checkout_of(path)` (`packages/claude-guard.py` 1571-1583) passes the real path of `WORKING["root"]` as `base` to `_checkout_of` (1590-1599), which walks up to the first `.git` and calls `own_worktree(real, base)` (1602-1626). `own_worktree` takes `base` for the main checkout three times: the place (`<base>/.claude/worktrees` or `<base>.worktrees`), the gitdir's parent (`<base>/.git/worktrees`) and the common dir (`<base>/.git`). With the root `<main>.worktrees/x`, a sibling `<main>.worktrees/y` fails all three.
- **Everything else goes through it.** `away_from_root`, `at_top` (so `same_checkout` and the `-C` drop), `in_checkout`, `project_file` and `resolve` (so `outside`, `secret_path` and `claude_config`) all call `checkout_of`. Nothing else calls `own_worktree`.
- **The gaps are real.** With the root `x`: `Edit <y>/.claude/skills/s/SKILL.md` gives no decision today (`resolve` returns no inside part, so `claude_config` is false), and `devenv.nix` 372-375 allows edits under `<main>.worktrees/**`. `echo x > ../src/b.rs` from `<y>/packages` gives no decision (`project_file` falls back to the cwd as the checkout).
- **The main checkout is already found.** `main_checkout()` (1664-1683, from #96) reads the root's `.git` file through `linked_git_dirs(top)` (1629-1643), which returns the gitdir and its common dir by real path, or None on any `OSError` or a `.git` that isn't such a file. `devenv.nix` 216-225 does the same reading for the sandbox and the Edit allow rule, from `<root>/.git` only.
- **The memo.** `CHECKOUTS` holds `checkout_of`'s answers by `(real path, base)`. `decide` clears it first thing (2786). The hook runs `decide` once per process.
- **The planned change gives these decisions**, root `<main>.worktrees/x` unless said:

  | Where | Call | Today | Planned |
  | --- | --- | --- | --- |
  | `<y>` | `git status`, `git log --oneline -5`, `git switch -c feat/y` | ask | allow |
  | `<y>/packages` | `git add a.py` | ask | allow |
  | `<y>/packages` | `scripts/check.sh` | ask | ask |
  | `<main>/.claude/worktrees/n/src` | `git log` | ask | allow |
  | a look-alike, a wrong `commondir`, another repository's worktree, a worktree elsewhere, one with no `commondir` | `git status` | ask | ask |
  | `<main>`, `<main>/sub` | `git status`, `git switch main` | ask | ask |
  | `<main>` | `git switch -c feat/x` | deny | deny |
  | `<x>` | `git -C <y> status` | none | none |
  | `<y>` | `git -C <y> status`, `git -C ../y status` | none | allow |
  | any | `Edit <y>/.claude/skills/s/SKILL.md`, `Edit <n>/.claude/settings.json` | none | ask |
  | any | `Write <y>/.git` | deny | deny |
  | any | `Write <y>/src/main.rs` | none | none |
  | any | `Edit <main>/.claude/settings.local.json` | none | none |
  | `<y>/packages` | `echo x > ../src/b.rs` (no scratch) | none | deny |
  | `<x>`, root a worktree with a relative `.git` file | `git status` | ask | allow |
  | `<x>` or `<y>`, root a worktree with no `commondir`, a submodule-style `.git` file, or a bare repository's worktree | `git status` | ask | ask |
  | the root itself, for each of those three roots | `git status` | allow | allow |

  No call raised an exception. The guard's existing cases all pass with the change patched in the same way.

Assumed:

- Other sessions are changing other parts of `claude-guard.py` at the same time, so the diff should stay in lines 1571-1645 (told by the planner's caller, not checked).
- With no Edit allow rule covering it, Claude Code's own rules prompt for an edit in the main checkout from a session rooted in a linked worktree, depending on the permission mode. Not tested here.

## Goals / Non-Goals

**Goals:**
- A session rooted in one of the project's worktrees gets, in a sibling worktree, the decisions a session rooted in the main checkout gets there.
- The same metadata checks apply to a sibling whatever the root is. Nothing is recognised that a main-rooted session wouldn't recognise.
- A root that isn't a linked worktree behaves exactly as before, and no reading of a strange `.git` file raises.
- The diff stays in one place in the guard.

**Non-Goals:**
- Making the main checkout a recognised checkout for a linked-rooted session (decided: it stays "away", so `git status` and `git switch main` there ask).
- The guard asking for `<main>/.claude` from a linked-rooted session. See Open Questions.
- A root that is a subdirectory of a worktree (`CLAUDE_PROJECT_DIR=<x>/packages`). Only `<root>/.git` is read, as `devenv.nix` does. Checked: such a session gets asks everywhere outside the root today and after.
- Changing `main_checkout()`, `tracking_create`, `devenv.nix`, or the absolute-path shell edit (`echo x > <y>/src/a.rs` from `<x>` gives no decision, as `echo x > <sib>/src/a.rs` from the main checkout gives none today).

## Decisions

### 1. Find the project once, then check siblings against it

A new helper beside `linked_git_dirs`:

```python
def project_base(base):
    """The directory the project's own worktrees are found from: base, the
    real path of the session's root, or the main checkout when base is a
    linked worktree ..."""
```

It calls `linked_git_dirs(base)`. If that gives a common dir whose name is `.git` and which is a directory, it returns that directory's parent. Otherwise it returns `base`. It reads only `<base>/.git`, and never walks up.

`checkout_of` passes both to `_checkout_of(real, base, project)`. `_checkout_of` keeps `if real == base: return base` and calls `own_worktree(real, project)`. `own_worktree` is unchanged except that its parameter is named `project`, which is what its docstring already calls it.

When the root is the main checkout, `linked_git_dirs` returns None (`.git` is a directory, and opening it raises `IsADirectoryError`, an `OSError`), `project == base`, and every path through the code is the one that runs today.

*Alternative: call `main_checkout()`.* Rejected. It walks up from the root with `repo_top`, so a root that is a subdirectory would start to count, which is wider than `devenv.nix`'s reading and than this change needs. It also returns None for no repository or a bare one, which would need a second fallback. And it sits in the part of the file the #96 rule owns; the decision was to leave it alone.

*Alternative: let `own_worktree` work out the main checkout from `here`'s own metadata* (accept any worktree whose common dir equals the root's). Rejected: it changes the function the security of the recognition rests on, for every caller, and the place check (`<project>.worktrees`, `<project>/.claude/worktrees`) still needs the project.

*Alternative: make the main checkout a recognised checkout too.* Rejected by decision before planning: #96's test pins `git switch main` in the main checkout as an ask for a linked-rooted session, and the Edit allow rule doesn't cover the main checkout for such a session, so the guard has less reason to speak there.

### 2. The root is not checked against the project

`project_base` doesn't require the root to pass `own_worktree(root, main)`. A root that is a worktree of the project somewhere else (`/elsewhere/wt`) still finds its siblings in `<main>.worktrees/`. A root whose `commondir` names another repository's `.git` takes that repository for the project.

Why: the root is where the user started the session, and the guard already accepts it with no check (`if real == base: return base`). Its `.git` file says which repository git itself uses there, which is the honest answer to "which project is this session in". `main_checkout()` reads it the same way for the switch rule. Each sibling still has to pass every check against that project.

*Alternative: require the root to pass `own_worktree`.* Rejected: it adds a second reading of the root and a third state (a linked root that isn't "own") with no mistake it would catch. A forged `.git` file at the root is forgery, not a mistake, and a session that can forge it can do more elsewhere.

### 3. Memoised in `CHECKOUTS`, under a key no path can make

`project_base` stores its answer in `CHECKOUTS[(None, base)]`. `checkout_of`'s keys are `(real path, base)`, and a real path is never None, so the two can't collide. `decide` already clears `CHECKOUTS`, so nothing outside lines 1571-1645 changes.

Why memoise: `checkout_of` runs for the cwd and for each path a command names, and each miss would read two files again.

*Alternative: a dict of its own, cleared in `decide`.* Cleaner to read, but it adds a line at 2786, where another session may be working, for no difference in behaviour. A comment at `CHECKOUTS` says what the second kind of key is.

*Alternative: no memo.* Rejected: two reads for each path of a long command, in a hook that runs before every tool call.

### 4. `own_worktree`'s checks stay as they are

The back-pointer check (the gitdir's `gitdir` file names `here` back) and the `commondir` check both stay, now against the main checkout. They are what keeps a look-alike, a worktree whose `commondir` leads elsewhere, and another repository's worktree out, and the new cases run each of them from a linked root.

### 5. Tests sit beside the existing ones, with a second sibling

The "project's own worktrees" block gains a worktree `y` (with `packages/`, `src/` and `.claude/skills/s/SKILL.md`), a submodule-style directory and a bare repository's worktree. New loops take a `session` as well as a `cwd`, and print both on failure. The existing loops keep `root=root` untouched.

In the #44 loop, `if session == sib and cwd == nested: continue` goes: the skip was there because `nested` wasn't recognised from `sib`. The spec's "wherever the session is rooted" (the requirement "A linked worktree creates and switches branches without a prompt") then holds for all four pairs. Checked: with the planned change patched in and the skip removed, in memory, the whole file reports `1328/1328 passed`, so every expectation in that loop holds for the pair and no existing case changes.

## Risks / Trade-offs

- **[A wider allow]** Sibling worktrees get allows they didn't get from a linked root. → They are exactly the allows a main-rooted session gets there, behind the same four checks (place, gitdir parent, back-pointer, `commondir`). Cases run a look-alike, a wrong `commondir`, another repository's worktree, a worktree elsewhere and one with no `commondir` from a linked root, and all still ask.
- **[A root's `.git` file decides the project]** A root whose `commondir` names another repository makes that repository the project (decision 2). → It is the repository git uses there. Not a mistake a session makes by accident; forging it needs a write under `.git`, which the guard denies and the sandbox protects.
- **[New decisions where there were none]** The `.claude` ask and the shell-edit deny now fire in sibling worktrees for linked-rooted sessions. A workflow that relied on the silence gets a prompt or a deny. → That is the fix. The deny's message already points to Edit and Write.
- **[A strange `.git` file]** A root with a `.git` file that is unreadable, not a `gitdir:` line, a submodule's, or a broken worktree's. → `linked_git_dirs` returns None for all of them (it catches `OSError`), and `project_base` returns the root: today's behaviour. Cases cover a missing `commondir`, a submodule-style file and a bare repository's worktree.
- **[A stale memo]** `CHECKOUTS` could carry a project from one call to the next. → `decide` clears it, and the hook is one call per process. The tests call `decide` for every case.
- **[Concurrent edits to the guard]** Two other sessions are changing the file. → The diff is confined to 1571-1645, and `decide` and `main_checkout()` aren't touched. A conflict there is resolved at merge, not here.
- **[The main checkout's `.claude` from a linked root]** The guard still says nothing about it. → See Open Questions; Claude Code's own rules decide, since no Edit allow rule covers it.

## Changes after review

Code review of the implementation led to four changes beyond the tasks:
- `own_worktree` also accepts `<root>/.claude/worktrees/<name>`, where EnterWorktree puts a worktree for a session rooted in a linked worktree. It takes the root as a third argument, and the gitdir, back-pointer and `commondir` checks still run against the main checkout.
- `linked_main(top)` holds the shared "linked worktree to main checkout" rule. `project_base` and `main_checkout()` both call it, so `main_checkout()`'s body changes after all: it now delegates, with the same behaviour.
- `linked_git_dirs` also catches `ValueError` (a `.git` file that isn't UTF-8, or has a NUL in it), since it now reads the root's file on every call.
- The two requirements were shortened to stay under strict validation's length limit.

## Migration Plan

Projects get it on their next module update. Nothing to migrate. Rollback is reverting the commit.

## Open Questions

- Should the guard ask before a file tool changes `<main>/.claude` from a session rooted in a linked worktree? Today and after this change it gives no decision (checked), and the Edit allow rule doesn't cover the main checkout for such a session (checked in `devenv.nix`), so Claude Code's own rules decide (assumed to prompt, depending on the mode). It can be answered later without changing this change's specs or tasks: it would be one more check in `resolve` or `claude_config`, and one scenario under "File tools ask before changing .git or Claude Code configuration".
