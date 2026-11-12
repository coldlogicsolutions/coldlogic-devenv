# Tasks

Run every tool through `devenv shell --quiet -- <cmd>`, one command per call, with no pipes. Change files only with Edit and Write. Design references are to design.md's numbered decisions. You work inside a session, so `CLAUDECODE` and `CLAUDE_CODE_CHILD_SESSION` are set in every command you run: never clear either to "try" the refresh for real. That would run devenv's link step inside the sandbox (#68). The real refresh is checked in section 5, from a terminal.

## 1. The script and its tests

- [ ] 1.1 Create `packages/claude-wrapper.sh` (decisions 1, 3, 4, 5). Start with `#!/usr/bin/env bash`, a header comment (what it is; that the developer shell puts it on `PATH` as `claude`; the refresh command; the three variables it reads: `CLAUDE_CODE_CHILD_SESSION`, `COLDLOGIC_CLAUDE_START_ANYWAY`, `COLDLOGIC_CLAUDE_WRAPPERS`; exit codes: Claude Code's own, 1 for a refusal, 127 for no Claude Code; that it uses only bash builtins, `git` and `devenv`), then `set -euo pipefail`. The body, in this order:

  1. `self="${BASH_SOURCE[0]}"`; when it doesn't start with `/`, `self="$PWD/$self"`. `git_bin="${git_bin:-git}"`. `seen="${COLDLOGIC_CLAUDE_WRAPPERS:-}"`.
  2. A function `is_wrapper <file>`: returns 0 when `[ "$1" -ef "$self" ]`, or when `$1` is `-ef` any non-empty element of `$seen` split on `:` (`IFS=: read -ra ws <<<"$seen"`); else 1. Write the tests as `if` statements, so `set -e` can't end the script on a false one.
  3. Find the real one: split `${PATH:-}` on `:` the same way; for each non-empty `dir`, `cand="$dir/claude"`; take the first where `[ -f "$cand" ] && [ -x "$cand" ]` and `is_wrapper "$cand"` is false. An empty entry is skipped, not read as the current directory.
  4. None found: print `coldlogic: no Claude Code found on PATH behind this wrapper ($self). Install Claude Code, or add it to PATH.` to stderr and `exit 127`. This comes before any refresh.
  5. `export COLDLOGIC_CLAUDE_WRAPPERS="${seen:+$seen:}$self"`.
  6. `if [ -n "${CLAUDE_CODE_CHILD_SESSION:-}" ]; then exec "$real" "$@"; fi`.
  7. The checkout: `top="$("$git_bin" rev-parse --show-toplevel 2>/dev/null)" || top=""`. `checkout="$top"` when `top` is non-empty and `$top/devenv.nix` or `$top/devenv.yaml` is a file; else `checkout="$DEVENV_ROOT"` when that is set and a directory; else empty.
  8. Empty: print `coldlogic: no devenv project found from $PWD, so the generated files weren't refreshed.` to stderr and `exec "$real" "$@"`.
  9. The refresh: `code=0`, then `(cd "$checkout" && unset CLAUDECODE && exec devenv --quiet tasks run devenv:files) </dev/null >/dev/null || code=$?`.
  10. `settings="$checkout/.claude/settings.json"`. When `code` isn't 0:
      - `[ -e "$settings" ]`: print `coldlogic: couldn't refresh the generated files in $checkout (devenv tasks run devenv:files exited $code). Starting claude with the settings already there, which may be out of date. To see why, run there: devenv shell` to stderr.
      - else, `COLDLOGIC_CLAUDE_START_ANYWAY` non-empty: print `coldlogic: couldn't refresh the generated files in $checkout (devenv tasks run devenv:files exited $code), and $settings is missing. Starting claude anyway, as COLDLOGIC_CLAUDE_START_ANYWAY is set: this session has none of the module's guard hook, sandbox settings or permissions.` to stderr.
      - else: print `coldlogic: not starting claude. Couldn't refresh the generated files in $checkout (devenv tasks run devenv:files exited $code), and $settings is missing, so the session would have none of the module's guard hook, sandbox settings or permissions. To see why, run there: devenv shell. To start it anyway: COLDLOGIC_CLAUDE_START_ANYWAY=1 claude` to stderr and `exit 1`.
  11. `exec "$real" "$@"`.

  Invariants, each of which a case in 1.2 holds:
  - Inside a session it runs no devenv and writes nothing: step 6 comes before step 7, and only `CLAUDE_CODE_CHILD_SESSION` decides it. This is what keeps devenv's `ln -sf` and cleanup's `rm` away from a sandboxed session's links (#68, #94).
  - `CLAUDECODE` is cleared only inside the refresh's subshell. The `exec` of the real `claude` sees it as the wrapper got it.
  - `"$@"` is never read, changed or re-split, and the wrapper's own directory never changes: the only `cd` is in the subshell.
  - The refresh can't read the wrapper's standard input (it may be a prompt piped to `claude -p`) or write to its standard output (it may be captured).
  - It never starts itself or a wrapper already in `COLDLOGIC_CLAUDE_WRAPPERS`, so no `PATH` can make it loop.
  - It never starts a session whose checkout has no readable settings after a failed refresh, unless the developer set the override.
  - It adds nothing to `PATH`.

  Verify: `devenv shell --quiet -- shellcheck --shell=bash packages/claude-wrapper.sh` reports nothing.

- [ ] 1.2 Create `packages/claude-wrapper-test.sh`, run as `bash packages/claude-wrapper-test.sh packages/claude-wrapper.sh`, in the style of `packages/session-relink-test.sh` (`set -eu`, a `mktemp -d` root removed by an EXIT trap, `fresh`, `check`, a final `N passed, M failed` and `[ "$failed" = 0 ]`). It needs bash and coreutils only.

  Setup:
  - First, `unset CLAUDECODE CLAUDE_CODE_CHILD_SESSION COLDLOGIC_CLAUDE_WRAPPERS COLDLOGIC_CLAUDE_START_ANYWAY DEVENV_ROOT git_bin`: the test is also run by hand inside a session.
  - `install_wrapper <dir>`: writes `<dir>/claude` as a first line `#!<output of command -v bash>` followed by the script from its second line on, and makes it executable. Every wrapper under test is one of these, started by its path, so `BASH_SOURCE` is what `PATH` would give.
  - `fresh`: a new `$case_dir` with `wrap/bin` (a wrapper installed), `stubs`, `real/bin`, `proj` (with an empty `devenv.nix`) and `log`; `cd "$case_dir/proj"`; resets the per-case settings below.
  - A fake real `claude` in `real/bin`: appends to `log/claude` one `ran` line, `cwd=$PWD`, `CLAUDECODE=${CLAUDECODE-unset}`, `wrappers=${COLDLOGIC_CLAUDE_WRAPPERS-unset}` and one `arg=<…>` line per argument; copies its standard input to `log/claude-stdin`; prints `claude-stdout`; exits `${STUB_CLAUDE_EXIT:-0}`.
  - A stub `devenv` in `stubs`: appends to `log/devenv` one `ran` line, `cwd=$PWD`, `args=$*` and `CLAUDECODE=${CLAUDECODE-unset}`; copies its standard input to `log/devenv-stdin`; prints `devenv-stdout` on standard output and `devenv-stderr` on stderr; exits `${STUB_DEVENV_EXIT:-0}`.
  - A stub `git` in `stubs`: for `rev-parse --show-toplevel`, prints `$STUB_GIT_TOP` and exits 0 when that is set, else exits 128.
  - `run <args…>`: runs `$entry` (default `$case_dir/wrap/bin/claude`) under `timeout 20`, with `PATH="$path"` (default `$case_dir/wrap/bin:$case_dir/stubs:$case_dir/real/bin:$PATH`), `STUB_GIT_TOP` (default `$case_dir/proj`), the case's extra variables, the logs' directory, and standard input from `$stdin_file` (default `/dev/null`). It sets `$code`, `$out` (standard output) and leaves stderr in `log/stderr`. The timeout turns a loop into a failure instead of a hung build.

  Cases, each ending in checks on `$code`, `$out` and the logs:
  - (a) `run -p 'a b' '' '*' --flag=x`: the `arg=` lines are exactly `<-p>`, `<a b>`, `<>`, `<*>`, `<--flag=x>`; `log/devenv` has `args=--quiet tasks run devenv:files`; `$out` is exactly `claude-stdout`; stderr holds only `devenv-stderr`.
  - (b) Standard input is a file holding `question`: `log/claude-stdin` holds `question` and `log/devenv-stdin` is empty.
  - (c) `STUB_CLAUDE_EXIT=7`: `$code` is 7.
  - (d) `CLAUDE_CODE_CHILD_SESSION=1` with `CLAUDECODE=1`: no `log/devenv`; claude ran with its arguments; nothing new in `proj`.
  - (e) `CLAUDECODE=1` alone, the IDE terminal: `log/devenv` has `CLAUDECODE=unset`, and `log/claude` has `CLAUDECODE=1`.
  - (f) Run from `proj/src/deep`: devenv's `cwd` is `proj`, claude's is `proj/src/deep`.
  - (g) `proj` has only `devenv.yaml`: devenv's `cwd` is `proj`.
  - (h) `STUB_GIT_TOP` is a directory with neither file, `DEVENV_ROOT=$case_dir/other`: devenv's `cwd` is `other`.
  - (i) `STUB_GIT_TOP` unset (git exits 128), `DEVENV_ROOT=$case_dir/other`: devenv's `cwd` is `other`.
  - (j) git exits 128 and no `DEVENV_ROOT`: no `log/devenv`, claude ran, stderr has `no devenv project found`.
  - (k) `STUB_DEVENV_EXIT=3`, `proj/.claude/settings.json` a link to an existing file: claude ran; stderr has `couldn't refresh`, `exited 3` and `may be out of date`.
  - (l) `STUB_DEVENV_EXIT=3`, no settings: `$code` is 1, no `log/claude`, stderr has `not starting claude`, the settings path and `COLDLOGIC_CLAUDE_START_ANYWAY=1 claude`.
  - (m) As (l), with the settings a link to a path that doesn't exist: the same refusal.
  - (n) As (l), with `COLDLOGIC_CLAUDE_START_ANYWAY=1`: claude ran; stderr has `Starting claude anyway`.
  - (o) As (l), with the settings a regular file: claude ran.
  - (p) No `devenv` stub (and `$path` without the outer `PATH`'s devenv: build `$path` from the three case directories and the directory of `command -v timeout` only), settings present: claude ran, stderr has `exited 127`.
  - (q) `STUB_DEVENV_EXIT=0`, no settings: claude ran and the wrapper printed nothing of its own (design decision 4: a refresh that succeeds is trusted).
  - (r) `$path` lists `wrap/bin` twice before `real/bin`: `log/claude` has one `ran` line, `log/devenv` one.
  - (s) `link/bin` is a link to `wrap/bin`, and `$path` is `link/bin`, `wrap/bin`, the rest; `$entry` is `link/bin/claude`: claude ran once.
  - (t) A second wrapper installed in `wrap2/bin`; `$path` is `wrap/bin`, `wrap2/bin`, the rest: claude ran once, and its `wrappers=` names both wrappers.
  - (u) As (t) with `real/bin` left off `$path`: `$code` is 127, not 124 (the timeout).
  - (v) No `real/bin` on `$path`: `$code` is 127, stderr has `no Claude Code found`, no `log/devenv`.
  - (w) Before `real/bin` on `$path`: a directory holding a non-executable file named `claude`, and one holding a directory named `claude`. Both are skipped and claude ran.
  - (x) `COLDLOGIC_CLAUDE_WRAPPERS` already holds the wrapper's own path, as a session's Bash tool would pass it: claude ran once.

  Verify: `devenv shell --quiet -- bash packages/claude-wrapper-test.sh packages/claude-wrapper.sh` ends with `0 failed`. Then check the tests bite, undoing each edit after: move step 6 of 1.1 after step 9 and confirm (d) fails; drop `unset CLAUDECODE` and confirm (e) fails; drop `</dev/null` and confirm (b) fails; drop `>/dev/null` and confirm (a) fails; make `is_wrapper` ignore `$seen` and confirm (u) fails; replace `[ -e "$settings" ]` with `[ -L "$settings" ]` and confirm (m) fails. Finally `devenv shell --quiet -- shellcheck --shell=bash packages/claude-wrapper-test.sh` reports nothing.

## 2. The package and the shell

- [ ] 2.1 Create `packages/claude-wrapper.nix`, a function of `{ pkgs }` (decision 6), after `packages/session-relink.nix`:
  - `tested`: `pkgs.runCommand "coldlogic-claude-wrapper-test"` with `nativeBuildInputs = with pkgs; [ bash coreutils ];`, running `bash ${./claude-wrapper-test.sh} ${./claude-wrapper.sh}` and `touch $out`.
  - `app`: `pkgs.writeShellApplication` with `name = "coldlogic-claude-wrapper"`, `runtimeInputs = [ ]`, and `text` made of `# Tested by ${tested}`, then `git_bin=${pkgs.git}/bin/git`, then `builtins.readFile ./claude-wrapper.sh`.
  - The result: `pkgs.runCommand "coldlogic-claude" { }` that makes `$out/bin` and links `$out/bin/claude` to `${app}/bin/coldlogic-claude-wrapper`.
  - A header comment: what it is, that its cases run at build, and why there are no `runtimeInputs` (they would be exported onto the `PATH` every session it starts inherits) and no nix `devenv` (the refresh must use the developer's own).

  Invariant: the package puts one name, `claude`, on `PATH`, and the built script contains no `export PATH`. Verify in 4.1.
- [ ] 2.2 In `devenv.nix`, add `claude-wrapper = import ./packages/claude-wrapper.nix { inherit pkgs; };` after the `prune-worktrees` binding (line 10), and add to the developer profile's `packages` (173-180), after `prune-worktrees`:

  ```nix
  # `claude`, ahead of the real one on PATH: refreshes the generated
  # files before it starts a session (packages/claude-wrapper.sh).
  claude-wrapper
  ```

  Touch no task: not the statuses, `coldlogic:session-files`, `coldlogic:generated-files-stale`, `coldlogic:prune-worktrees`, `coldlogic:worktree-hooks-path` or `coldlogic:openspec-files` (decision 2, and the overlap list in design.md). Verify: `devenv shell --quiet -- git diff --stat devenv.nix` shows only these additions and 2.3's two comment lines, and `devenv shell --quiet -- devenv build shell` succeeds, which runs 1.2's cases in the Nix build.
- [ ] 2.3 In `devenv.nix`, bring two comments up to date, changing nothing else. At 53-54, "Only a terminal shell refreshes it." becomes "Only a terminal shell refreshes it, or the `claude` wrapper before a session starts." At 507-509, "which only a terminal shell refreshes" becomes "which only a terminal shell or the `claude` wrapper, before a session starts, refreshes". Verify: `devenv shell --quiet -- nixfmt --check devenv.nix packages/claude-wrapper.nix` passes (run `nixfmt` on both first).
- [ ] 2.4 In `scripts/check.sh`, in the comment above `step "build: shell"` (106-107), add claude-wrapper's to the build-time tests it lists. Verify by reading the comment.

## 3. The spec's Purpose and the README

- [ ] 3.1 Edit the Purpose of `openspec/specs/generated-files/spec.md` directly (a delta can't carry it) to:

  `How the generated links (`.claude/settings.json`, `.mcp.json`, `.pre-commit-config.yaml` and the rest) are kept current around a Claude Code session, whose sandbox can't safely rewrite them. A session never runs devenv's file tasks or writes the settings link; it relinks the rest atomically and reports what it can't fix. Outside a session, a terminal `devenv shell` refreshes them, and so does the `claude` wrapper before it starts one. A stale link mustn't break the shell or leave the session with no settings (#37, #94, #101).`

  Change nothing else in that file: the requirements change on archive. Verify: `devenv shell --quiet -- openspec validate --all --strict` passes.
- [ ] 3.2 In `README.md`, add a "What's here" row after the `packages/prune-worktrees.nix` row, and leave the `devenv.nix` row as it is (the parallel change may edit it):

  `| `packages/claude-wrapper.nix` | `claude`, ahead of the real Claude Code on the developer shell's `PATH`. Outside a session it first refreshes the checkout's generated files (`devenv --quiet tasks run devenv:files`, at the top of the checkout the current directory is in), so every session it starts has current settings; then it starts the real `claude` with the same arguments, directory and streams. Inside a session (`CLAUDE_CODE_CHILD_SESSION` set) it only starts it. If the refresh fails it says so, and starts `claude` only when `.claude/settings.json` is there, unless `COLDLOGIC_CLAUDE_START_ANYWAY=1` is set. Its cases in `claude-wrapper-test.sh` run when it builds |`

  Verify by reading the rendered table: one new row, no other row changed.
- [ ] 3.3 In `README.md`, add a section `## Starting Claude Code` after "Using it", saying, in short sentences:
  - Start `claude` from the devenv shell (`devenv shell` or direnv), in the checkout. The wrapper refreshes the generated files first, so there is no need to enter a shell and restart sessions after a module update: restart `claude`.
  - Every `claude` command waits for that refresh, `claude --version` included.
  - It only works where the shell's `PATH` is used. The IDE extension's own launch and the desktop app don't go through it: for those, enter the shell from a terminal once, as before.
  - Start it in the checkout whose settings it should read. In a subdirectory the checkout's files are refreshed, but Claude Code looks for `.claude/settings.json` where it starts.
  - The refresh uses the profile `devenv.yaml` selects, whatever `--profile` the shell was entered with.
  - Sessions need Claude Code 2.1.172 or later, which sets `CLAUDE_CODE_CHILD_SESSION`; it is how the wrapper knows a session started it.
  - A session that started without the settings and is still open can remove the link again (#100): close it.
  - The failure behaviour and `COLDLOGIC_CLAUDE_START_ANYWAY=1 claude`.
  - To run the real binary without the wrapper, take its path from `type -a claude`.

  Verify: every command the section names is spelled as the script and this change's spec spell it.

## 4. Checks from the session

- [ ] 4.1 Run `devenv shell --quiet -- printenv PATH` and verify the directory of the new `coldlogic-claude` store path comes before the real `claude`'s directory (`/opt/homebrew/bin` on Derek's machine). Read that directory's `claude` (a link to the application) and verify: the line `git_bin=/nix/store/…/bin/git` is there, there is no `export PATH`, and the `bin` directory holds only `claude`.
- [ ] 4.2 Run `devenv shell --quiet -- claude --version`. In a session this takes the wrapper's session branch. Verify it prints Claude Code's version, and that `ls -la .claude` and `readlink .mcp.json` show the same as before the call. If the guard asks about the command, say so in the PR and leave the check to 5.1.
- [ ] 4.3 Run `devenv shell --quiet -- openspec validate claude-wrapper --strict` and verify it reports the change valid.

## 5. Checks from a terminal (Derek, before merge)

The session can't make these: they need a shell outside any session. Each records its result in the PR. A failure of 5.1 to 5.3 goes back to design.md before the merge.

- [ ] 5.1 Cost. In the main checkout's devenv shell, run `time claude --version` three times, then once more after `touch devenv.nix`. Record the warm and the after-change times. Verify the warm time is acceptable; if it is over two seconds, stop and raise design.md's open question 2.
- [ ] 5.2 `PATH` under direnv. In a fresh terminal, `cd` into the checkout (direnv loads) and run `type -a claude`. Verify the first entry is the `coldlogic-claude` store path and the real one follows.
- [ ] 5.3 The refresh is real, and stays in its checkout. In a worktree with no `.claude/settings.json`, reached by `cd` from the main checkout's `devenv shell` (so `DEVENV_ROOT` is the main checkout), note `readlink` of the main checkout's `.claude/settings.json` and the time of its `.devenv` state's `files.json`, then run `claude --version`. Verify the worktree's `.claude/settings.json` now links into the store, and the main checkout's link and `files.json` are unchanged.
- [ ] 5.4 A stale link. Point the checkout's `.claude/settings.json` at another store file (`ln -sfn`), run `claude --version`, and verify the link is back on the current path.
- [ ] 5.5 An IDE terminal and teammates. In an IDE extension's terminal, run `printenv CLAUDECODE CLAUDE_CODE_CHILD_SESSION` (expect only the first), repeat 5.4 there, and verify the link is refreshed. Then start an agent team in a session and note whether each teammate's start runs the refresh (`ps` shows a `devenv tasks run`) and what it costs.
- [ ] 5.6 Failure. Add a syntax error to `devenv.nix` and run `claude --version`: verify the warning and that it starts. Move `.claude/settings.json` aside and run it again: verify the refusal, exit code 1, and that `COLDLOGIC_CLAUDE_START_ANYWAY=1 claude --version` starts. Restore both.

## 6. Gate

- [ ] 6.1 Run `devenv shell --quiet -- scripts/check.sh` and verify it ends with `check: all passed`.

## Workflow follow-up

- If `session-fresh-worktrees` lands first, rebase this change's copy of "A session never writes the settings link" onto its wording before archiving (design.md, the overlap list).
- Archive the change on the feature branch as the last commit before the PR merges.
