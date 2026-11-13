# Tasks

Run the guard's cases with `devenv shell --quiet -- python3 -I packages/claude-guard-test.py`. It prints `N/N passed` and exits 0 when every case passes, and a `FAIL` line for each case that doesn't. Every expectation below was produced by running the planned change (design.md, Context). A different decision means the implementation differs from design.md: fix the code, not the expectation, or stop and ask.

Change only `packages/claude-guard.py` between `def checkout_of` and the end of `linked_git_dirs` (lines 1571-1645 on this branch), the two places named in `packages/claude-guard-test.py`, and one sentence in `README.md`. Other sessions are changing other parts of the guard. Don't touch `decide`, `main_checkout()` or `devenv.nix`.

## 1. Cases first (design decision 5)

All in `packages/claude-guard-test.py`, in the block that starts `# The project's own worktrees, wherever they sit (agent worktrees).`

- [x] 1.1 Add to the fixture, after the `nocd` lines and before `policy =`:
  - `y = os.path.join(top, "proj.worktrees", "y")`, made with `linked(root, y, "y")`, with the directories `packages`, `src` and `.claude/skills/s`, and an empty file `.claude/skills/s/SKILL.md`.
  - `subm = os.path.join(top, "proj.worktrees", "subm")`: a submodule-style checkout. Make the directories `<root>/.git/modules/subm` and `subm`, and write `subm/.git` as `gitdir: <root>/.git/modules/subm\n`. No `commondir`, no `gitdir` file.
  - `bw = os.path.join(top, "bare.git.worktrees", "bw")`: a worktree of a bare repository `bare = os.path.join(top, "bare.git")`. Make `bare/worktrees/bw` and `bw`; write `bw/.git` as `gitdir: <bare>/worktrees/bw\n`, `bare/worktrees/bw/commondir` as `..\n`, and `bare/worktrees/bw/gitdir` as `<bw>/.git\n`.

  Verify: run the cases; the count is unchanged and all pass (the fixture alone changes no decision).
- [x] 1.2 Inside the block's outer `try`, after the scratch-stubbed loop's `finally: guard.scratch = real_scratch`, add a loop over `(session, cwd, command, expected)` that sets `guard.WORKING.update(cwd=cwd, root=session)`, calls `guard.decide("Bash", {"command": command}, policy)` and reports `FAIL {command!r} in {cwd}, session in {session}: expected ..., got ...`. Head it with a comment: a session that starts in a linked worktree (#65) finds the project's other worktrees from the main checkout, and nothing else. Cases, with `P = os.path.join`:
  - Siblings are judged like the root (invariant: the same decision a main-rooted session gets there, a deny and an ask included):
    `(sib, y, "git status", "allow")`, `(sib, y, "git log --oneline -5", "allow")`, `(sib, y, "git switch -c feat/y", "allow")`, `(sib, y, "git switch -f main", "ask")`, `(sib, y, "git push --force", "deny")`, `(sib, P(y, "packages"), "git add a.py", "allow")`, `(sib, P(y, "packages"), "scripts/check.sh", "ask")`, `(sib, y, "devenv shell --quiet -- scripts/check.sh", "allow")`, `(sib, rel, "git status", "allow")`, `(sib, nested, "git status", "allow")`, `(sib, P(nested, "src"), "git log", "allow")`.
  - What isn't the project's own worktree still isn't (threat: a look-alike, a foreign or misplaced worktree getting the project's allows through the new lookup):
    `(sib, fake, "git status", "ask")`, `(sib, bc, "git status", "ask")`, `(sib, ow, "git status", "ask")`, `(sib, away, "git status", "ask")`, `(sib, under_sub, "git status", "ask")`, `(sib, nocd, "git status", "ask")`.
  - The main checkout stays outside a linked-rooted session's project:
    `(sib, root, "git status", "ask")`, `(sib, P(root, "sub"), "git status", "ask")`, `(nested, root, "git status", "ask")`.
  - `-C` (invariant: only a `-C` naming the checkout the command runs in is dropped; another checkout's top is kept, since git would read relative arguments from there):
    `(sib, sib, f"git -C {y} status", None)`, `(sib, y, f"git -C {y} status", "allow")`, `(sib, y, "git -C ../y status", "allow")`, `(sib, y, f"git -C {sib} status", None)`, `(sib, sib, f"git -C {root} status", None)`, `(sib, sib, "cat ../y/README.md", None)`.
  - Other linked roots: a relative `.git` file, a worktree under `.claude`, and a worktree elsewhere (design decision 2):
    `(rel, sib, "git status", "allow")`, `(rel, y, "git status", "allow")`, `(rel, rel, "git status", "allow")`, `(nested, sib, "git status", "allow")`, `(nested, P(y, "packages"), "git add a.py", "allow")`, `(away, sib, "git status", "allow")`.
  - Roots whose `.git` file names no main checkout, or another repository's (threat: an exception in the hook, or siblings recognised from a root that doesn't belong to the repository):
    `(nocd, nocd, "git status", "allow")`, `(nocd, sib, "git status", "ask")`, `(nocd, y, "git status", "ask")`, `(subm, subm, "git status", "allow")`, `(subm, sib, "git status", "ask")`, `(bw, bw, "git status", "allow")`, `(bw, sib, "git status", "ask")`, `(bc, sib, "git status", "ask")`.

  Verify: run the cases. Before group 2, exactly these fail, each with `got ask` or `got None` where `allow` is expected: the eight `allow` cases with `sib` as the session and a cwd in `y`, `rel` or `nested`; the two `-C` cases in `y`; `(rel, sib)`, `(rel, y)`, `(nested, sib)`, `(nested, y/packages)` and `(away, sib)`. Every other new case passes already. If any other fails, stop: the fixture is wrong.
- [x] 1.3 After that loop, add one over `(session, cwd, tool, path, expected)` calling `guard.decide(tool, {"file_path": path}, policy)`, with the same failure message shape. Cases:
  - The fixed gap (threat: a session changing another worktree's Claude Code configuration with no prompt, since the Edit allow rule covers `<main>.worktrees/**`):
    `(sib, sib, "Edit", f"{y}/.claude/skills/s/SKILL.md", "ask")`, `(sib, y, "Edit", f"{y}/.claude/skills/s/SKILL.md", "ask")`, `(sib, sib, "Write", f"{y}/.claude/settings.json", "ask")`, `(sib, sib, "Edit", f"{nested}/.claude/settings.json", "ask")`.
  - Unchanged around it:
    `(sib, sib, "Write", f"{y}/.git", "deny")`, `(sib, sib, "Write", f"{y}/src/main.rs", None)`, `(sib, sib, "Write", f"{nested}/src/main.rs", None)`, `(sib, sib, "Edit", f"{sib}/.claude/skills/y/SKILL.md", "ask")`, `(sib, sib, "Edit", f"{ow}/.claude/settings.json", None)`, `(sib, sib, "Edit", f"{fake}/.claude/settings.json", None)`, `(nocd, nocd, "Edit", f"{y}/.claude/skills/s/SKILL.md", None)`, `(subm, subm, "Edit", f"{y}/.claude/skills/s/SKILL.md", None)`.
  - The main checkout isn't this session's project, so Claude Code's own rules decide (design.md, Open Questions; say so in a comment):
    `(sib, sib, "Edit", f"{root}/.claude/settings.local.json", None)`.

  Verify: run the cases. Before group 2, exactly the four fixed-gap cases fail, with `got None`.
- [x] 1.4 After that, with `guard.scratch` stubbed to `lambda path: False` and restored in a `finally` as the existing loop does, add `(session, cwd, command, expected)` cases through `guard.decide("Bash", ...)`:
  - The fixed gap (threat: a Bash call changing a project file in a sibling worktree past the shell-edit deny):
    `(sib, P(y, "packages"), "echo x > ../src/b.rs", "deny")`.
  - Unchanged around it:
    `(sib, y, "echo x > src/a.rs", "deny")`, `(sib, y, f"echo x > {top}/elsewhere.txt", None)`, `(sib, P(sib, "packages"), "echo x > ../src/b.rs", "deny")`, `(nocd, P(y, "packages"), "echo x > ../src/b.rs", None)`.

  Verify: run the cases. Before group 2, only the first fails, with `got None`.

## 2. The lookup (design decisions 1 to 4)

All in `packages/claude-guard.py`, lines 1571-1645.

- [x] 2.1 Add `project_base(base)` directly after `linked_git_dirs`. `base` is the real path of the session's root. Body: look up `key = (None, base)` in `CHECKOUTS`; on a miss, call `linked_git_dirs(base)`; the answer is `os.path.dirname(common)` when that returned `(gitdir, common)` with `os.path.basename(common) == ".git"` and `os.path.isdir(common)`, else `base`; store and return it. It must read only `<base>/.git` (no walk up, no `repo_top`, no `main_checkout()`), and must not raise: `linked_git_dirs` already returns None on any `OSError` or a `.git` that is no `gitdir:` file. Docstring: what it returns, that the root is taken at its word as git takes it (design decision 2), that each worktree is still checked against the result by `own_worktree`, and that it matches `devenv.nix`'s `mainCheckout`. Invariant: for a root that is not a linked worktree it returns `base`, so nothing changes there. Verify: the file still loads (the cases run and the count is unchanged).
- [x] 2.2 In `checkout_of`, change the miss to `CHECKOUTS[key] = _checkout_of(real, base, project_base(base))`, and give `_checkout_of` the third parameter `project`. In `_checkout_of` keep `if real == base: return base` first and unchanged, and change only the call to `own_worktree(real, project)`. Invariant: the root is still returned for itself and everything under it with no other `.git` on the way, and the walk still stops at the first `.git`, so a nested repository or a look-alike is never walked past. Update `checkout_of`'s docstring: the project's worktrees are found from the main checkout when the root is itself one of them (#65), and the main checkout is then not one of the session's checkouts. Change the comment at `CHECKOUTS = {}` to say it also holds `project_base`'s answer under `(None, base)`, a key no path makes. Verify: run the cases; every case from group 1 passes and the whole file prints `N/N passed`.
- [x] 2.3 In `own_worktree`, rename the parameter `base` to `project` (five uses) and change nothing else. Its four checks stay exactly as they are: the place, the gitdir's parent, the back-pointer and the `commondir`. Threat they guard: a directory that only claims to be the project's worktree getting the project's allows. Verify: `own_worktree(` appears in the file only at its definition and in `_checkout_of`, and the cases still all pass.
- [x] 2.4 In `packages/claude-guard-test.py`, in the #44 loop of the "main checkout stays on main" block, delete the two lines `if session == sib and cwd == nested:` and `continue`. A worktree under `.claude` is now recognised from a session rooted in a sibling, so that pair runs too. Verify: the cases all pass and the count has grown by that pair's cases.
- [x] 2.5 In `README.md`, in the `packages/claude-guard.py` row, after the sentence "The main checkout is found from the project root, through a linked worktree's `.git` file when the session starts in one.", add: "The project's own worktrees are found from it the same way, so a session that starts in one treats the others as a session in the main checkout does, their `.claude` directories and shell edits included; the main checkout itself stays outside that session's project." Verify: the row still renders as one table row (no line break added).

## 3. Integration

- [x] 3.1 Run `devenv shell --quiet -- openspec validate guard-linked-root-siblings --strict` and verify it reports the change valid.
- [x] 3.2 Run `devenv shell --quiet -- git diff --stat` and verify only `packages/claude-guard.py`, `packages/claude-guard-test.py`, `README.md` and this change's files are listed, and that the guard's hunks all lie between `def checkout_of` and `MAIN_CHECKOUT =`.
- [x] 3.3 Run the gate, `devenv shell --quiet -- scripts/check.sh`, and verify it passes.

## Workflow follow-up

- Open the PR with `Closes #65`.
- After merge, in a fresh session started in a linked worktree (an agent worktree will do), once `devenv shell` has been entered there so the hook updates: `git status` run in another of the project's worktrees must not prompt, and an Edit of that worktree's `.claude/skills/...` must ask.
- Archive the change after review.
