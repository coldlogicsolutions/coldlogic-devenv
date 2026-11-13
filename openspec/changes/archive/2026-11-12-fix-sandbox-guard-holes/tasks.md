# Tasks

Run every tool through `devenv shell --quiet -- <cmd>`, one command per call, no pipes. Design references are to design.md's numbered decisions.

Other sessions are editing `packages/claude-guard.py` (lines 253-625, 1046-1240, 1571-1680 and from 2810 on). In that file, change only the function `claude_config()`. Do not touch `resolve()`, `checkout_of()` or `decide()`. Line numbers below are from the branch point and may have moved: find each place by the quoted text.

## 1. Guard: a link in `.claude` asks (#56)

- [x] 1.1 In `packages/claude-guard-test.py`, add a new block between the end of the `.claude` block (the line `guard.WORKING.update(cwd=None, root=None)` that follows `print(f"FAIL {tool} {path}: expected {expected}, got {got}")`, near 1233) and the comment `# The project's own worktrees, wherever they sit (agent worktrees).`. Do not edit the existing `.claude` block (decision 3). The block:

  ```python
  # A link in `.claude` asks wherever it leads (#56): devenv's settings.json is
  # a link into the Nix store. A link elsewhere is judged by where it leads.
  with tempfile.TemporaryDirectory() as top:
      top = os.path.realpath(top)
      root = os.path.join(top, "proj")
      store = os.path.join(top, "store")
      os.makedirs(os.path.join(root, ".claude", "worktrees", "x", "src"))
      os.makedirs(store)
      generated = os.path.join(store, "settings.json")
      open(generated, "w").close()
      os.symlink(generated, os.path.join(root, ".claude", "settings.json"))
      # A link whose target is missing.
      os.symlink(os.path.join(store, "missing.json"), os.path.join(root, ".claude", "settings.local.json"))
      # Links outside `.claude`: one into it, one out of the project.
      os.symlink(os.path.join(root, ".claude", "local.json"), os.path.join(root, "alias.json"))
      os.symlink(generated, os.path.join(root, "notes.json"))
      # A link in a worktree under `.claude` is that checkout's file.
      os.symlink(generated, os.path.join(root, ".claude", "worktrees", "x", "src", "main.rs"))
      try:
          for cwd, tool, path, expected in [
              (root, "Edit", f"{root}/.claude/settings.json", "ask"),
              (root, "Write", f"{root}/.claude/settings.json", "ask"),
              (root, "MultiEdit", f"{root}/.claude/settings.json", "ask"),
              (root, "Edit", ".claude/settings.json", "ask"),
              (os.path.join(root, ".claude"), "Edit", "settings.json", "ask"),
              (root, "Write", f"{root}/.claude/settings.local.json", "ask"),
              (root, "Edit", f"{root}/alias.json", "ask"),
              (root, "Edit", f"{root}/notes.json", None),
              (root, "Write", f"{root}/.claude/worktrees/x/src/main.rs", None),
              (root, "Read", f"{root}/.claude/settings.json", None),
          ]:
              guard.WORKING.update(cwd=cwd, root=root)
              got = guard.decide(tool, {"file_path": path}, POLICY)
              checks += 1
              got = got[0] if got else None
              if got != expected:
                  failures += 1
                  print(f"FAIL {tool} {path} in {cwd} (linked): expected {expected}, got {got}")
      finally:
          guard.WORKING.update(cwd=None, root=None)
  ```

  Verify: `devenv shell --quiet -- python3 -I packages/claude-guard-test.py` now reports exactly six failures, all with `(linked)`: the Edit, Write, MultiEdit, relative and in-`.claude` cases on `settings.json`, and the Write on `settings.local.json`. The `alias.json`, `notes.json`, worktree and Read cases already pass. If any other case fails, stop: the block's setup is wrong, not the guard.
- [x] 1.2 In the "project's own worktrees" block of the same file, add the sibling-worktree and other-repository cases (decision 3):
  - In the setup, directly after the line `open(os.path.join(sib, ".claude", "skills", "y", "SKILL.md"), "w").close()`, add:

    ```python
    # Generated settings: a link out of the project, in the project's own
    # worktree (asks) and in another repository's (left alone).
    store = os.path.join(top, "store")
    os.makedirs(store)
    open(os.path.join(store, "settings.json"), "w").close()
    os.symlink(os.path.join(store, "settings.json"), os.path.join(sib, ".claude", "settings.json"))
    ```

  - Directly after the line `linked(other, ow, "w")`, add:

    ```python
    os.makedirs(os.path.join(ow, ".claude"))
    os.symlink(os.path.join(store, "settings.json"), os.path.join(ow, ".claude", "settings.json"))
    ```

    `store` is defined earlier in the block by the first addition; keep that order.
  - In the list that starts `for cwd, tool, path, expected in [` and holds `(sib, "Edit", f"{sib}/.claude/skills/y/SKILL.md", "ask"),`, add these rows before the existing last row `(sib, "Edit", f"{ow}/.claude/settings.json", None),` and leave that row as it is:

    ```python
    (sib, "Edit", f"{sib}/.claude/settings.json", "ask"),
    (root, "Write", f"{sib}/.claude/settings.json", "ask"),
    (sib, "Read", f"{sib}/.claude/settings.json", None),
    ```

  The existing `{ow}` row now names a link and must still expect `None`. Invariant it protects: only the project's own checkouts count; another repository's `.claude` is never the guard's to ask about. Verify: the test run now also fails the two new `"ask"` rows (`FAIL Edit .../proj.worktrees/x/.claude/settings.json in ...` and the Write from `root`), the Read row and the `{ow}` row pass, and no Bash case in that block changed.
- [x] 1.3 In `packages/claude-guard.py`, replace the whole of `claude_config()` (decisions 1 and 2) with:

  ```python
  def claude_config(path):
      """Whether a path inside the project is in a `.claude` directory, other
      than inside one of its worktrees (`.claude/worktrees/<name>/...`), which
      are checkouts of the project. A path is judged by where it leads and by
      where it sits (its directory resolved, its own name kept), so a link in
      `.claude` counts wherever it leads: devenv's settings.json is a link
      into the Nix store."""
      views = []
      where = resolve(path)
      if where is not None and where[1] is not None:
          views.append(where[1])
      head, name = os.path.split(os.path.expanduser(path).rstrip("/"))
      if name not in ("", ".", ".."):
          parent = resolve(head)
          if parent is not None and parent[1] is not None:
              views.append(os.path.normpath(os.path.join(parent[1], name)))
      for inside in views:
          parts = unicodedata.normalize("NFKC", inside).casefold().split(os.sep)
          i = 0
          while i < len(parts):
              if parts[i] == ".claude":
                  if parts[i + 1:i + 2] == ["worktrees"] and len(parts) > i + 3:
                      i += 3
                      continue
                  return True
              i += 1
      return False
  ```

  The inner loop is the existing one, unchanged, run per view. Threat it covers: a file-tool write that replaces or edits the session's own settings, hooks, skills or agents without a prompt because the file is a link. Invariants: (a) for a path whose last component isn't a symlink both views are the same string, so no existing decision changes; (b) "inside the project" is still only what `resolve()` says, so the root and the project's own worktrees count and nothing else; (c) `.`, `..` and an empty name get only the resolved view. Verify: `devenv shell --quiet -- python3 -I packages/claude-guard-test.py` ends with `N/N passed`, where N is the count before this change plus 13 (10 from 1.1, 3 from 1.2), and prints no `FAIL` line.
- [x] 1.4 Check the scope of the edit. Verify: `devenv shell --quiet -- git diff --stat` lists only `packages/claude-guard.py` and `packages/claude-guard-test.py` so far, and `devenv shell --quiet -- git diff packages/claude-guard.py` shows a single hunk, inside `claude_config()`.

## 2. Guard: how to test it (#79)

- [x] 2.1 In `README.md`, under `## Working on the module`, after the paragraph "It exits non-zero if any check failed, and the pull request runs it again as the `check` job." and before `## Staying current`, add (decision 6):

  ````markdown
  ### Testing the guard

  To find out what the guard decides for a command, don't run the command. The guard judges a call; it doesn't contain it. Whatever it lets through runs for real, and so does anything a probe script leaves behind when a heredoc ends early (#79: a reviewer's probe posted PR comments and made a commit).

  Use one of these instead:

  - Add a case to `packages/claude-guard-test.py` and run the cases:

    ```
    devenv shell --quiet -- python3 -I packages/claude-guard-test.py
    ```

  - Load `packages/claude-guard.py` in Python, as the first lines of that test file do, and call `guard.decide("Bash", {"command": "<the command>"}, policy)` on the command as a string. It returns the decision and its reason, or `None` when the call is left to Claude Code's rules.

  This holds for reviewers and subagents too: the command under test stays a string.
  ````

  Do not change the table row for `packages/claude-guard.py`. Verify: the documented command runs as written and ends with `N/N passed`; `devenv shell --quiet -- git diff README.md` shows only added lines, all in this subsection.

## 3. Sandbox: deny writes under `secrets/` (#59)

- [x] 3.1 In `devenv.nix`, change the entry `{ path = "secrets/**"; }` in the `secrets` list to (decision 4):

  ```nix
  {
    path = "secrets/**";
    denyWrite = true;
  }
  ```

  Change nothing in the `denyWrite =` expression under `sandbox.filesystem`: its filter picks the entry up. Threat it covers: a sandboxed Bash command writing or replacing a file under a `secrets` directory that Read, Edit and the sandbox's read deny already keep it out of. Verify: `devenv shell --quiet -- nixfmt --check devenv.nix` reports nothing.
- [x] 3.2 Update the comments in the same list so they match. Leave the comment that starts `# What no session reads or writes, at any depth in the checkout.` as it is: "one with `denyWrite` also a sandbox denyWrite entry" stays true. In the `.env` entry's comment, replace the sentence "A write deny overrides allowWrite, so only `.env` itself is write-denied; the guard hook keeps other `.env.*` files from being written by name." with "A write deny overrides allowWrite, so of the `.env` files only `.env` itself is write-denied; the guard hook keeps other `.env.*` files from being written by name. `secrets/**` below is write-denied whole." Re-wrap to the file's comment width. Verify: `devenv shell --quiet -- nixfmt --check devenv.nix` reports nothing, and `devenv shell --quiet -- git diff devenv.nix` shows changes only in the `secrets` list.
- [x] 3.3 Check the generated settings. A session can't regenerate them (in a session devenv's file tasks are skipped, and this worktree may have no `.claude/settings.json` at all), so this needs a terminal outside any session: `devenv shell --quiet -- true` in this worktree. Then read `.claude/settings.json` with the Read tool and confirm `sandbox.filesystem.denyWrite` holds all four of: `<this worktree>/secrets/**`, `<this worktree>/**/secrets/**`, `<main checkout>.worktrees/*/secrets/**`, `<main checkout>.worktrees/*/**/secrets/**`, beside the four `.env` entries that were already there. If no such terminal is available to you, leave this task unchecked and say so in the handback; it is then a check for the user. No automated test is added (decision 5). Do not try a live write under `secrets/` from Bash to test the sandbox: the guard denies such a command before the sandbox sees it, so it proves nothing about the sandbox.

## 4. Gate

- [x] 4.1 Run `devenv shell --quiet -- openspec validate fix-sandbox-guard-holes --strict`. Verify: it reports the change as valid.
- [x] 4.2 Run the gate: `devenv shell --quiet -- scripts/check.sh`. Verify: it ends with `check: all passed`. `guard tests` and `build: shell` (which runs the guard's cases in the Nix build) must both pass. Do not pipe it or follow it with anything but `&&`.

## Workflow follow-up

- The pull request closes #56 and #59. It refers to #79 without closing it: the review guidance in the plugin repository is separate.
- #59 asked for a test; none is added (design decision 5). Say so in the pull request.
- Archive the change after review, which updates `openspec/specs/claude-guard/spec.md` and `openspec/specs/session-permissions/spec.md`.
