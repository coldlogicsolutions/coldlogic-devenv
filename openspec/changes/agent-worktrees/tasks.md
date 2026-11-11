# Tasks

Run the guard's cases with `devenv shell --quiet -- python3 -I packages/claude-guard-test.py`. It prints `N/N passed` and exits 0 when every case passes. A different decision from the one a task lists means the implementation differs from design.md: fix the code, not the expectation, or stop and ask.

## 1. Recognise the project's own worktrees anywhere, and resolve paths in them (design decisions 1 and 2)

- [x] 1.1 In `packages/claude-guard-test.py`, in the "seventh review" block (around line 516), also write `os.path.join(root, ".git", "worktrees", "x", "commondir")` with content `"../..\n"`, so the fixture is a complete linked worktree. Verify the test file still passes against the unchanged guard.
- [x] 1.2 In `packages/claude-guard.py`, make `own_worktree(here, base)` also require `<gitdir>/commondir`. Read it, strip it, resolve it with `os.path.realpath(os.path.join(gitdir, value))`, and require it to equal `os.path.realpath(os.path.join(base, ".git"))`. A missing file returns `False` through the existing `except OSError`. Update its docstring to name both layouts (`.claude/worktrees/<name>` and `<project>.worktrees/<name>`). Verify the existing cases still pass.
- [x] 1.3 Add `checkout_of(path)` next to `at_top()`, as design decision 1 describes. Take `real = os.path.realpath(path)` and `base = os.path.realpath(WORKING["root"] or WORKING["cwd"])`, then loop. If `real == base`, return `base`. If `os.path.lexists(os.path.join(real, ".git"))`, return `real` if `own_worktree(real, base)` else `None`. Otherwise go to the parent, and return `None` once the parent equals `real`. Rewrite `away_from_root()` to `return checkout_of(cwd) is None` and `at_top()` to `return checkout_of(cwd) == os.path.realpath(cwd)`. Keep both functions' early returns for an unknown cwd or root, and update their docstrings. Verify the existing cases still pass.
- [x] 1.4 Change `resolve(path)`. When the path is outside the root, call `top = checkout_of(resolved)`. Return `(resolved, ".")` if `resolved == top`, and `(resolved, os.path.relpath(resolved, top))` if `top` is not `None` and isn't the root. Otherwise return `(resolved, None)`. Paths inside the root keep today's root-relative result. This is what lets `plain_args()` accept bare words such as `status` in a sibling worktree. Verify every existing case still passes, in particular the `.claude` block (`<root>/.claude/worktrees/x/src/main.rs` → None, `<root>/.claude/worktrees/x` → ask).
- [x] 1.5 Add a block to `claude-guard-test.py`, before the final `total = checks`, headed `# The project's own worktrees, wherever they sit (agent worktrees).` Build it in `tempfile.TemporaryDirectory()` with `top = os.path.realpath(top)` and a helper `linked(root, wt, name)`. The helper creates `root/.git/worktrees/<name>/`, writes `wt/.git` = `gitdir: <that dir>\n`, writes `<that dir>/gitdir` = `<wt>/.git\n` and writes `<that dir>/commondir` = `../..\n`. Lay out:
  - `root = top/proj`, with `os.makedirs(root/.git/worktrees)` and `root/sub/`
  - `sib = top/proj.worktrees/x`, linked as `x`, with dirs `packages/`, `src/`, `vendor/lib/.git/` and the file `.claude/skills/y/SKILL.md`
  - `nested = root/.claude/worktrees/n`, linked as `n`, with `src/`
  - `fake = top/proj.worktrees/fake`, whose `.git` file names `root/.git/worktrees/x` (x's gitdir names `sib`, not `fake`)
  - `bc = top/proj.worktrees/bc`, linked as `bc`, but with `commondir` overwritten to the absolute path `top/other/.git`
  - `other = top/other` with `other/.git/worktrees/w/`, and `ow = top/other.worktrees/w`, linked to `other` as `w`

  Use a policy of `POLICY` plus `"git switch *"` in allow and `"git switch -f *"` in ask. For each `(cwd, command, expected)`, set `guard.WORKING.update(cwd=cwd, root=root)` and compare `decide("Bash", …)[0]` (or `None`), failing like the other blocks. Reset `WORKING` in a `finally`. Cases:
  - `(sib, "git status", "allow")`
  - `(sib, "git log --oneline -5", "allow")`
  - `(sib, "git switch -c feat/y", "allow")`
  - `(sib, "git switch -f main", "ask")`
  - `(sib, "git add packages/a.py", "allow")`
  - `(sib/packages, "git add a.py", "allow")`
  - `(sib/packages, "scripts/check.sh", "ask")`
  - `(sib, "devenv shell --quiet -- scripts/check.sh", "allow")`
  - `(sib, "git push --force", "deny")`
  - `(sib/vendor/lib, "git status", "ask")`
  - `(sib, "cat ../y/README.md", None)`
  - `(nested/src, "git log", "allow")`
  - `(fake, "git status", "ask")`
  - `(bc, "git status", "ask")`
  - `(ow, "git status", "ask")`

  Verify all of them pass, and that the whole file still passes.

## 2. File tools and shell edits in the project's own worktrees (design decision 2)

- [x] 2.1 In `project_file()`, replace the second base `os.path.realpath(cwd or root)` with `checkout_of(cwd)` when `cwd` is set and that isn't `None`. Otherwise keep `os.path.realpath(cwd or root)`. Verify the existing "sibling worktree" block (no `.git` there, so the fallback applies) still passes.
- [x] 2.2 Extend the group 1 block with file-tool cases, each `(cwd, tool, path, expected)` checked with `decide(tool, {"file_path": path}, policy)`:
  - `(sib, "Edit", f"{sib}/.claude/skills/y/SKILL.md", "ask")`
  - `(root, "Edit", f"{sib}/.claude/skills/y/SKILL.md", "ask")`
  - `(sib, "Edit", f"{root}/.claude/settings.local.json", "ask")`
  - `(sib, "Write", f"{sib}/src/main.rs", None)`
  - `(sib, "Write", f"{sib}/.git", "deny")`
  - `(sib, "Edit", f"{ow}/.claude/settings.json", None)`

  Then add shell-edit cases, run with `guard.scratch` replaced by `lambda path: False` (restore it in `finally`, as the existing sibling block does, since the temp dir otherwise counts as scratch):
  - `(sib/packages, "echo x > ../src/b.rs", "deny")`
  - `(sib, "echo x > src/a.rs", "deny")`
  - `(sib, f"echo x > {top}/elsewhere.txt", None)`

  Verify all pass, together with the group 1 cases.

## 3. Drop `git -C` naming one of the project's checkouts (design decision 3)

- [x] 3.1 In `normalize_git()`, replace `if value not in (".", "./"):` with `if value not in (".", "./") and not checkout_dir(value):`. Add `checkout_dir(value)`: it returns `False` unless `WORKING["cwd"]` and `WORKING["root"]` are set and `at_top()` holds. Otherwise take `real = os.path.realpath(value if os.path.isabs(value) else os.path.join(WORKING["cwd"], value))` and return `checkout_of(real) == real`. Update the comment above it to say which `-C` values are dropped. Verify the existing cases still pass, including `("git -C . push --force", DENY)` and `devenv --quiet shell -- git -C /x reset --hard HEAD~1` → DENY.
- [x] 3.2 Extend the group 1 block with:
  - `(sib, f"git -C {sib} status", "allow")`
  - `(root, f"git -C {sib} log --oneline", "allow")`
  - `(sib, f"git -C {root} status", "allow")`
  - `(root, f"git -C {nested} status", "allow")`
  - `(sib, "git -C . status", "allow")`
  - `(root/sub, f"git -C {sib} status", None)`
  - `(sib, f"git -C {sib}/packages status", None)`
  - `(sib, f"git -C {fake} status", None)`
  - `(sib, f"git -C {other} status", None)`
  - `(sib, f"git -C {sib} push --force", "deny")`

  Verify all pass.

## 4. Sandbox and Edit rule (design decisions 4 and 5)

- [x] 4.1 In `devenv.nix`'s developer module `let`, add `mainCheckout` and `siblingWorktrees` exactly as in design decision 4, with a comment. Say why the main checkout is used: agents spawned from a worktree land beside the main checkout. Say that the layout comes from a `WorktreeCreate` hook that places worktrees at `<main>.worktrees/<name>`. Run `devenv shell --quiet -- nixfmt devenv.nix` (or let the gate's nixfmt hook run). Verify `devenv --profile developer eval devenv.root claude.code.permissions.rules.Edit.allow` still evaluates.
- [x] 4.2 Append `"/${siblingWorktrees}/**"` to `rules.Edit.allow`, and `siblingWorktrees` to `sandbox.filesystem.allowWrite`. Extend the comments beside each: the Edit rule now covers sibling worktrees too, and allowWrite gets one entry for the project's own sibling worktrees (subagents' `isolation: worktree`, #45), with no other project's. Verify with `devenv --profile developer eval claude.code.permissions.rules.Edit.allow`, which must list `//Users/derekjw/Projects/coldlogic-devenv/**` and `//Users/derekjw/Projects/coldlogic-devenv.worktrees/**`. Also run the same eval from inside `/Users/derekjw/Projects/coldlogic-devenv.worktrees/<any existing>` with `devenv --profile developer eval claude.code.permissions.rules.Edit.allow`. It must still name `coldlogic-devenv.worktrees`, not `<name>.worktrees`. If the sandbox blocks the eval there, note that and leave the check to 6.1.
- [x] 4.3 Append `"/tmp/devenv-*"` and `"/private/tmp/devenv-*"` to `sandbox.filesystem.allowWrite`, with a comment. devenv's runtime dir is `/tmp/devenv-<hash of the checkout>`, so a fresh worktree's first shell creates a new one (#45). The glob reaches other devenv projects' runtime dirs too. Skip this task if Derek declines it (design.md, Open Questions), and say so in the PR.
- [x] 4.4 Verify the guard package still builds, which runs `claude-guard-test.py` (`packages/claude-guard.nix`): `devenv shell --quiet -- true` must succeed without a `coldlogic-claude-guard` build failure. Verify `devenv shell --quiet -- python3 -I packages/claude-guard-test.py` prints all cases passed.

## 5. Docs and specs

- [x] 5.1 In `README.md`, in the `packages/claude-guard.py` row, add that a linked worktree of the project's own repository (under `.claude/worktrees` or beside the checkout in `<checkout>.worktrees`) is judged like the root, and that `git -C` naming one of them is too. In the `devenv.nix` row, add that the sandbox may write the checkout's sibling `.worktrees` directory and devenv's `/tmp/devenv-*` runtime dirs. If 4.3 was skipped, leave out the runtime dirs. Verify by reading the rows back.
- [x] 5.2 Run `devenv shell --quiet -- openspec validate agent-worktrees --strict` and verify it reports the change valid. If 4.3 was skipped, first remove `/tmp/devenv-*` and the "A fresh worktree's first shell" scenario from `specs/session-permissions/spec.md`.

## 6. Integration check (needs Derek: a terminal shell and a fresh session)

- [ ] 6.1 Derek enters `devenv shell` once from a terminal in the main checkout, so the settings relink. Then `jq '.sandbox.filesystem.allowWrite, .permissions.allow' .claude/settings.json` must list `/Users/derekjw/Projects/coldlogic-devenv.worktrees` (and `/tmp/devenv-*` unless 4.3 was skipped) and the new Edit rule.
- [ ] 6.2 In a new Claude Code session, start a subagent with `isolation: worktree`. Have it run, each as its own Bash call: `git status`, `git log --oneline -3`, `git switch -c probe/agent-worktrees --no-track`, `git -C <its worktree> diff`, `devenv shell --quiet -- true` and `touch .devenv/probe`. Verify none prompts and none fails on the sandbox, and that the first `devenv shell` created a new `/tmp/devenv-<hash>` (unless 4.3 was skipped). If the glob isn't honoured, try `/private/tmp/devenv-*/**` per design.md's Risks before giving up on it. Remove the probe branch and file afterwards.

## Workflow follow-up

- Open the PR with `Closes #42`, `Closes #44` and `Refs #45`. #45's `.git/config` item stays open (design.md, Non-Goals).
- Archive the change after review and the integration check.
