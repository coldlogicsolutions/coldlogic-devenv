# Tasks

Other sessions are editing `packages/claude-guard.py` and `packages/claude-guard-test.py`. Make only the edits below, at the anchors named, with Edit. Don't reformat, reorder or rename anything else, and don't touch `devenv.nix`. Line numbers are from `3666ba8` and may have moved; find each anchor by its text.

Run the guard's tests with `devenv shell --quiet -- python3 -I packages/claude-guard-test.py`. It prints `N/N passed`, or a `FAIL` line per wrong case.

## 1. The regression table, first

- [x] 1.1 In `packages/claude-guard-test.py`, add the block below at the end of the file, directly above the line `total = checks`, with one blank line before and after it. Copy it as written; every expected value was checked against a prototype of group 2. Verify: against the guard at `3666ba8` the run ends `1429/1453 passed` with 24 `FAIL` lines, and every one of them is a command starting `devenv --version`, `devenv -V` or `devenv version` (16 `FAIL module allow list` lines, 2 more from the temporary-directory part, and 6 `FAIL devenv version query` lines). Every git and gh-app row already passes. The totals shift if another session's cases have landed; what must hold is that no other kind of row fails. If one does, stop and report it: the guard on this branch differs from the one this plan was checked against.

  ```python
  # The module's own allow list, copied from devenv.nix (rules.Bash.allow):
  # keep the two in step. Below it, every command from issues #42, #43, #61,
  # #62, #85 and #86, each run bare and behind `devenv shell --quiet --`.
  MODULE_ALLOW = [
      "scripts/check.sh", "git status *", "git diff *", "git log *", "git add *",
      "git commit *", "git switch *", "git branch *", "git worktree *",
      "git fetch *", "git rev-list *",
      "gh-app pr view *", "gh-app pr checks *", "gh-app pr list *",
      "gh-app pr comment *", "gh-app pr create *", "gh-app pr merge *",
      "gh-app issue create *", "gh-app issue view *", "gh-app issue list *",
      "gh-app issue comment *", "gh-app issue edit *", "openspec *",
  ]
  MODULE = [
      # #42: read-only git.
      ("git log", ALLOW),
      ("git log --oneline -5", ALLOW),
      ("git log --oneline | head -5", ALLOW),
      ("git log -p -1", ALLOW),
      ("git log --format=%h%x20%s -3", ALLOW),
      ("git log origin/main..HEAD", ALLOW),
      ("git log --oneline -- packages/claude-guard.py", ALLOW),
      ("git -C . log --oneline -5", ALLOW),
      ("git status", ALLOW),
      ("git status --short", ALLOW),
      ("git diff", ALLOW),
      ("git diff origin/main...HEAD", ALLOW),
      ("git diff --stat HEAD~1", ALLOW),
      # What the guard refuses for any allowed git.
      ("git -C /elsewhere log", NONE),
      ("git log --output=x", ASK),
      ("git -c core.pager=x log", ASK),
      ("git log $(rm -rf x)", NONE),
      ("git log -1 && git push --force", DENY),
      ("git log -1; rm -rf build", NONE),
      # No rule names these: Claude Code's own rules decide.
      ("git show HEAD", NONE),
      ("git blame README.md", NONE),
      ("git rev-parse HEAD", NONE),
      # #85: the devenv version query, and nothing else of devenv's.
      ("devenv --version", ALLOW),
      ("devenv -V", ALLOW),
      ("devenv version", ALLOW),
      ("devenv --version && git status", ALLOW),
      ("devenv --version | head -1", ALLOW),
      ("devenv --version 2>&1", ALLOW),
      ("devenv --version shell -- rm -rf x", ASK),
      ("devenv -V shell -- git push --force", DENY),
      ("devenv --version extra", ASK),
      ("devenv --quiet --version", ASK),
      ("devenv --versio", ASK),
      ("devenv --help", ASK),
      ("/nix/store/x/bin/devenv --version", ASK),
      ("devenv --weird-flag shell -- ls", ASK),
      ("devenv version --help", NONE),
      ("devenv update", NONE),
      ("devenv up", NONE),
      ("devenv shell", NONE),
      ("devenv shell --quiet -- rm -rf build", NONE),
      ("devenv --version; rm -rf build", NONE),
      ("devenv --version > out.txt", DENY),
      ("devenv version; git push --force", DENY),
      # #43: issues and pull requests as the App, with a body.
      ("gh-app issue view 42 --json title,body,comments", ALLOW),
      ("gh-app issue list", ALLOW),
      ("gh-app issue list --state open --search guard", ALLOW),
      ("gh-app pr list", ALLOW),
      ("gh-app issue create --title t --body 'line1\nline2 with `code` and $(x)'", ALLOW),
      ("gh-app issue create --title t --body \"line1\nline2\"", ALLOW),
      ("gh-app issue create --title t --body-file \"$TMPDIR/body.md\"", ALLOW),
      ("gh-app issue create --title t --body-file /private/tmp/claude-501/scratch/body.md", ALLOW),
      ("gh-app issue comment 5 --body-file \"$TMPDIR/body.md\"", ALLOW),
      ("gh-app issue edit 5 --body-file \"$TMPDIR/body.md\"", ALLOW),
      ("gh-app pr create --title t --body-file \"$TMPDIR/body.md\"", ALLOW),
      # A double-quoted body with backticks or `$` runs what it holds, and a
      # body in `$( )` is a substitution: the supported forms are above.
      ("gh-app issue create --title t --body \"uses `git status` here\"", NONE),
      ("gh-app issue create --title t --body \"uses `gh pr merge 5` here\"", DENY),
      ("gh-app issue create --title t --body \"costs $HOME\"", NONE),
      ("gh-app issue create --title t --body \"$(cat <<'EOF'\nRun gh pr merge 5.\nEOF\n)\"", NONE),
      # #61: a body on stdin that quotes forbidden commands.
      ("gh-app issue create --title t --body-file - <<'EOF'\nRun gh pr merge 55 --auto --squash, then git push --force.\nEOF", ALLOW),
      ("gh-app issue create --title t --body-file - <<'EOF' 2>&1 | grep 'https://'\ngh pr merge 55\nEOF", ALLOW),
      ("gh-app issue create --title t --body-file - <<EOF\nx\nEOF", NONE),
      # #62: auto-merge as the App.
      ("gh-app pr merge 31 --auto --squash", ALLOW),
      ("gh-app pr merge 31 -R coldlogicsolutions/claude-plugins-coldlogic --auto --squash", ALLOW),
      ("gh-app pr merge --auto --squash 31", ALLOW),
      ("gh pr merge 31 --auto --squash", DENY),
      # #86: another repository's issues.
      ("gh-app issue comment 78 -R coldlogicsolutions/coldlogic-devenv --body \"plain text\"", ALLOW),
      ("gh-app issue comment 49 -R coldlogicsolutions/coldlogic-devenv --body-file /private/tmp/claude-501/scratch/comment-49.md", ALLOW),
      ("gh-app issue create -R coldlogicsolutions/coldlogic-devenv --title t --body x", ALLOW),
      ("gh-app issue view 78 -R coldlogicsolutions/coldlogic-devenv", ALLOW),
      ("gh-app issue list -R coldlogicsolutions/coldlogic-devenv", ALLOW),
      ("gh-app issue comment 78 --body-file /etc/passwd", ASK),
      ("gh-app issue comment 78", ASK),
      # A cd changes what the rules and paths after it mean.
      ("cd /Users/x/Projects/infrastructure && devenv shell --quiet -- gh-app issue comment 78 "
       "-R coldlogicsolutions/coldlogic-devenv --body x", NONE),
  ]
  FUNCTION = "gh() { devenv shell --quiet -- gh-app \"$@\"; }\ngh pr merge 55 --auto --squash"
  module_policy = {"allow": MODULE_ALLOW}
  for command, expected in (
          [(c, e) for command, e in MODULE for c in (command, "devenv shell --quiet -- " + command)]
          # #61: a function named gh asks. Behind the wrapper only its first
          # line is wrapped, and the guard falls back to its rough reading.
          + [(FUNCTION, ASK), ("devenv shell --quiet -- " + FUNCTION, DENY)]):
      got = guard.decide("Bash", {"command": command}, module_policy)
      checks += 1
      got = got[0] if got else None
      if got != expected:
          failures += 1
          print(f"FAIL module allow list {command!r}: expected {expected}, got {got}")

  # The same list where the session's directory is known: `-C` naming it.
  with tempfile.TemporaryDirectory() as top:
      root = os.path.join(os.path.realpath(top), "p")
      os.makedirs(os.path.join(root, "sub"))
      open(os.path.join(root, "README.md"), "w").close()
      guard.WORKING.update(cwd=root, root=root)
      try:
          for command, expected in [
              (f"git -C {root} log --oneline -5", ALLOW),
              (f"git -C {root} status", ALLOW),
              ("git -C . status", ALLOW),
              (f"git -C {root}/sub log", NONE),
              ("devenv --version", ALLOW),
          ]:
              for c in (command, "devenv shell --quiet -- " + command):
                  got = guard.decide("Bash", {"command": c}, module_policy)
                  checks += 1
                  got = got[0] if got else None
                  if got != expected:
                      failures += 1
                      print(f"FAIL module allow list in {root} {c!r}: expected {expected}, got {got}")
      finally:
          guard.WORKING.update(cwd=None, root=None)

  # The devenv version query only reads, so it needs no rule; an ask or deny
  # rule still wins, and a rule for the wrapper doesn't change what's inside.
  for policy, command, expected in [
      ({}, "devenv --version", ALLOW),
      ({}, "devenv -V", ALLOW),
      ({}, "devenv version", ALLOW),
      ({}, "devenv shell --quiet -- devenv --version", ALLOW),
      ({"allow": ["devenv shell *"]}, "devenv shell --quiet -- devenv --version", ALLOW),
      ({"ask": ["devenv *"]}, "devenv --version", ASK),
      ({"deny": ["devenv *"]}, "devenv --version", DENY),
      ({"ask": ["devenv --version"]}, "devenv shell --quiet -- devenv --version", ASK),
      ({}, "devenv --version shell -- rm -rf x", ASK),
      ({"allow": ["devenv shell *"]}, "devenv shell --quiet -- rm -rf build", ASK),
      ({"allow": ["devenv *"]}, "devenv update", NONE),
  ]:
      got = guard.decide("Bash", {"command": command}, policy)
      checks += 1
      got = got[0] if got else None
      if got != expected:
          failures += 1
          print(f"FAIL devenv version query {policy} {command!r}: expected {expected}, got {got}")
  ```

## 2. The devenv version query (#85)

Invariant: only the exact word lists `devenv --version`, `devenv -V` and `devenv version` stop being a wrapper and count as read-only. Anything longer, any other spelling of the program or the option, keeps today's reading, so nothing can ride behind the option (`devenv --version shell -- <anything>` still asks, and is still denied when it holds a forbidden command), and every other devenv option the guard doesn't know still asks.

The fix needs three small edits, not one in `devenv_command()` alone: that function stops the ask, but the strict reader separately refuses any program in `WRAPPERS`, which holds `devenv`, and `approved()` needs either a rule or `read_only()`.

- [x] 2.1 In `packages/claude-guard.py`, directly above `def devenv_command(words):`, add:

  ```python
  # The whole of a devenv version query: it prints the version and runs
  # nothing, so it is a command that only reads, not a wrapper.
  DEVENV_VERSION = (["--version"], ["-V"], ["version"])


  def version_query(words):
      """Whether these words are exactly a devenv version query, with the
      program spelled `devenv` and nothing after: a path to it, another
      option before or after, or an abbreviation is not one."""
      return words[0] == "devenv" and words[1:] in DEVENV_VERSION
  ```

  Keep two blank lines before `def devenv_command`. Verify: the test file still runs, with the same failures as after 1.1.
- [x] 2.2 In `devenv_command()`, between its docstring and `i = 1`, add:

  ```python
      if version_query(words):
          return None
  ```

  This makes `unwrap()` keep `["devenv", "--version"]` as the command instead of raising `Unparsable`. Don't touch the loop below: `raise Unparsable(f"devenv option {w}")` must still be reached for every other option. Verify: the rows `devenv --version shell -- rm -rf x`, `devenv --version extra`, `devenv --quiet --version`, `devenv --versio`, `devenv --help`, `devenv --weird-flag shell -- ls` and `/nix/store/x/bin/devenv --version` still pass as ASK.
- [x] 2.3 In `plain_commands()`, in the inner `end()`, change the one line

  ```python
          if "=" in run[0] or head in WRAPPERS | SHELLS or head in NOT_PLAIN:
  ```

  to

  ```python
          if "=" in run[0] or (head in WRAPPERS | SHELLS and not version_query(run)) or head in NOT_PLAIN:
  ```

  `run` is the command with a leading `devenv shell [--quiet|-q] --` already removed, so the wrapped form is covered by the same test. Don't remove `devenv` from `WRAPPERS`: `unwrap()` and the heredoc reader checks rely on it. Verify: the file still runs; the `devenv` ALLOW rows still fail (2.4 finishes them).
- [x] 2.4 In `read_only()`, between its docstring and `if words[0] not in READ_ONLY:`, add:

  ```python
      if version_query(words):
          return True
  ```

  and change the docstring's one line to `"""Whether this is a READ_ONLY command reading only inside the project, or a devenv version query."""`. Don't add `devenv` to `READ_ONLY`: that set is matched by program name alone in `stage_kind()` and `data_consumer()`, and would make every `devenv` command a read-only pipeline stage. `read_only()` is called only from `approved()`, after `plain_args()`. Verify: the whole test file passes, `N/N passed` with no `FAIL` line (`1453/1453` on `3666ba8`).

## 3. Documentation

- [x] 3.1 In `README.md`, in the `packages/claude-guard.py` row of the table (it starts `| \`packages/claude-guard.py\` | The PreToolUse guard hook:`), after the sentence ending `or a scratch file under \`$TMPDIR\` keep a call allowed.`, insert: ``Exactly `devenv --version`, `devenv -V` and `devenv version` count as commands that only read; any other `devenv` option the guard doesn't know asks.`` Keep the row on one line. Verify: the row still renders as one table row (no newline added).

## 4. The gate

- [x] 4.1 Run `devenv shell --quiet -- openspec validate guard-allowed-commands-group1 --strict` and fix anything it reports in this change's files.
- [x] 4.2 Run the gate on its own, `devenv shell --quiet -- scripts/check.sh` (to keep its output, redirect it to `"$TMPDIR/check.log"` and read that; don't pipe it). Verify: it ends `check: all passed`. `build: shell` rebuilds the guard package, which runs the test file again inside the build.

## Workflow follow-up

- This change closes #42, #43, #61 and #85. #62 and #86 stay open: comment on them with what the table shows (the guard allows those commands, bare and wrapped) and the likely causes in design.md.
- Archive the change after review.
