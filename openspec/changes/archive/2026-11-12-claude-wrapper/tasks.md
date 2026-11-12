# Tasks

Run every tool through `devenv shell --quiet -- <cmd>`, one command per call, with no pipes. Change files only with Edit and Write. Design references are to design.md's numbered decisions. You work inside a session, so `CLAUDECODE` and `CLAUDE_CODE_CHILD_SESSION` are set in every command you run: never clear them to "try" the refresh or a file task for real. That would run devenv's link step inside the sandbox (#68). The real refresh is checked in section 6, from a terminal.

## 1. The script and its tests

- [x] 1.1 Create `packages/claude-wrapper.sh` (decisions 1, 3, 4, 5, 6). Start with `#!/usr/bin/env bash`, a header comment (what it is; that the developer shell puts it on `PATH` as `claude`; the refresh command; the variables it reads: `COLDLOGIC_DEVENV_SESSION`, `CLAUDE_CODE_CHILD_SESSION`, `COLDLOGIC_START_WITHOUT_SETTINGS`, `COLDLOGIC_WRAPPERS_RUN`; the two it sets: `COLDLOGIC_DEVENV_SESSION` and `COLDLOGIC_WRAPPERS_RUN`; exit codes: Claude Code's own, 1 for a refusal, 127 for no Claude Code; that it uses only bash builtins, `git` and `devenv`), then `set -euo pipefail`. The body, in this order:

  1. `self="${BASH_SOURCE[0]}"`; when it doesn't start with `/`, `self="$PWD/$self"`. `git_bin="${git_bin:-git}"`. `seen="${COLDLOGIC_WRAPPERS_RUN:-}"`.
  2. `nested=""`, then `nested=1` when `COLDLOGIC_DEVENV_SESSION` is non-empty or `CLAUDE_CODE_CHILD_SESSION` is. Read both here, before step 5 exports the marker.
  3. A function `is_wrapper <file>`: returns 0 when `[ "$1" -ef "$self" ]`, or when `$1` is `-ef` any non-empty element of `$seen` split on `:` (`IFS=: read -ra ws <<<"$seen"`); else 1. Write the tests as `if` statements, so `set -e` can't end the script on a false one.
  4. Find the real one: split `${PATH:-}` on `:` the same way; for each non-empty `dir`, `cand="$dir/claude"`; take the first where `[ -f "$cand" ] && [ -x "$cand" ]` and `is_wrapper "$cand"` is false. An empty entry is skipped, not read as the current directory. None found: print `coldlogic: no Claude Code found on PATH behind this wrapper ($self). Install Claude Code, or add it to PATH.` to stderr and `exit 127`. This comes before any refresh.
  5. `export COLDLOGIC_WRAPPERS_RUN="${seen:+$seen:}$self"` and `export COLDLOGIC_DEVENV_SESSION=1`. From here every `exec` of the real `claude` carries both.
  6. `if [ -n "$nested" ]; then exec "$real" "$@"; fi`.
  7. The checkout: `top="$("$git_bin" rev-parse --show-toplevel 2>/dev/null)" || top=""`. `checkout="$top"` when `top` is non-empty and `$top/devenv.nix` or `$top/devenv.yaml` is a file; else empty. Never `DEVENV_ROOT` (review fix R2).
  8. Empty: `exec "$real" "$@"`, with no message (review fix R2).
  9. The refresh: `code=0`, then, in a subshell, `cd "$checkout"`, `unset CLAUDECODE COLDLOGIC_DEVENV_SESSION` and every `DEVENV_` variable (`"${!DEVENV_@}"`, review fix R1), and `exec devenv --quiet tasks run devenv:files`, with `</dev/null >/dev/null`; `|| code=$?`.
  10. `settings="$checkout/.claude/settings.json"`. When `code` is 0, print nothing and don't look at `$settings`. When it isn't:
      - `[ -e "$settings" ]`: print `coldlogic: couldn't refresh the generated files in $checkout (devenv tasks run devenv:files exited $code). Starting claude with the settings already there, which may be out of date. To see why, run there: devenv shell` to stderr.
      - else, `COLDLOGIC_START_WITHOUT_SETTINGS` non-empty: print `coldlogic: couldn't refresh the generated files in $checkout (devenv tasks run devenv:files exited $code), and $settings is missing. Starting claude anyway, as COLDLOGIC_START_WITHOUT_SETTINGS is set: this session has none of the module's guard hook, sandbox settings or permissions.` to stderr.
      - else: print `coldlogic: not starting claude. Couldn't refresh the generated files in $checkout (devenv tasks run devenv:files exited $code), and $settings is missing, so the session would have none of the module's guard hook, sandbox settings or permissions. To see why, run there: devenv shell. To start it anyway: COLDLOGIC_START_WITHOUT_SETTINGS=1 claude` to stderr and `exit 1`.
  11. `exec "$real" "$@"`.

  Invariants, each of which a case in 1.2 holds:
  - Inside a session it runs no devenv and writes nothing: step 6 comes before step 7, and only the two variables of step 2 decide it. This is what keeps devenv's `ln -sf` and cleanup's `rm` away from a sandboxed session's links (#68, #94).
  - `CLAUDECODE` is not part of the wrapper's own test: an IDE terminal sets it, and the refresh must run there.
  - The marker and `CLAUDECODE` are cleared only inside the refresh's subshell. The real `claude` always gets the marker, and gets `CLAUDECODE` as the wrapper got it. If the marker leaked into the refresh, the shell's test (section 3) would skip the file tasks and the refresh would silently do nothing.
  - `"$@"` is never read, changed or re-split, and the wrapper's own directory never changes: the only `cd` is in the subshell.
  - The refresh can't read the wrapper's standard input (it may be a prompt piped to `claude -p`) or write to its standard output (it may be captured).
  - It never starts itself or a wrapper already in `COLDLOGIC_WRAPPERS_RUN`, so no `PATH` can make it loop.
  - After a failed refresh it never starts a session whose checkout has no readable settings, unless the developer set the override.
  - It adds nothing to `PATH`.

  Verify: `devenv shell --quiet -- shellcheck --shell=bash packages/claude-wrapper.sh` reports nothing.

- [x] 1.2 Create `packages/claude-wrapper-test.sh`, run as `bash packages/claude-wrapper-test.sh packages/claude-wrapper.sh`, in the style of `packages/session-relink-test.sh` (`set -eu`, a `mktemp -d` root removed by an EXIT trap, `fresh`, `check`, a final `N passed, M failed` and `[ "$failed" = 0 ]`). It needs bash and coreutils only.

  Setup:
  - First, `unset CLAUDECODE CLAUDE_CODE_CHILD_SESSION COLDLOGIC_DEVENV_SESSION COLDLOGIC_WRAPPERS_RUN COLDLOGIC_START_WITHOUT_SETTINGS DEVENV_ROOT git_bin`: the test is also run by hand inside a session.
  - `install_wrapper <dir>`: writes `<dir>/claude` as a first line `#!<output of command -v bash>` followed by the script from its second line on, and makes it executable. Every wrapper under test is one of these, started by its path, so `BASH_SOURCE` is what `PATH` would give.
  - `fresh`: a new `$case_dir` with `wrap/bin` (a wrapper installed), `stubs`, `real/bin`, `proj` (with an empty `devenv.nix`) and `log`; `cd "$case_dir/proj"`; resets the per-case settings below.
  - A fake real `claude` in `real/bin`: appends to `log/claude` one `ran` line, `cwd=$PWD`, `CLAUDECODE=${CLAUDECODE-unset}`, `session=${COLDLOGIC_DEVENV_SESSION-unset}`, `wrappers=${COLDLOGIC_WRAPPERS_RUN-unset}` and one `arg=<…>` line per argument; copies its standard input to `log/claude-stdin`; prints `claude-stdout`; exits `${STUB_CLAUDE_EXIT:-0}`.
  - A stub `devenv` in `stubs`: appends to `log/devenv` one `ran` line, `cwd=$PWD`, `args=$*`, `CLAUDECODE=${CLAUDECODE-unset}` and `session=${COLDLOGIC_DEVENV_SESSION-unset}`; copies its standard input to `log/devenv-stdin`; prints `devenv-stdout` on standard output and `devenv-stderr` on stderr; exits `${STUB_DEVENV_EXIT:-0}`.
  - A stub `git` in `stubs`: for `rev-parse --show-toplevel`, prints `$STUB_GIT_TOP` and exits 0 when that is set, else exits 128.
  - `run <args…>`: runs `$entry` (default `$case_dir/wrap/bin/claude`) under `timeout 20`, with `PATH="$path"` (default `$case_dir/wrap/bin:$case_dir/stubs:$case_dir/real/bin:$PATH`), `STUB_GIT_TOP` (default `$case_dir/proj`), the case's extra variables, the logs' directory, and standard input from `$stdin_file` (default `/dev/null`). It sets `$code`, `$out` (standard output) and leaves stderr in `log/stderr`. The timeout turns a loop into a failure instead of a hung build.

  Cases, each ending in checks on `$code`, `$out` and the logs:
  - (a) `run -p 'a b' '' '*' --flag=x`: the `arg=` lines are exactly `<-p>`, `<a b>`, `<>`, `<*>`, `<--flag=x>`; `log/devenv` has `args=--quiet tasks run devenv:files` and `session=unset`; `log/claude` has `session=1`; `$out` is exactly `claude-stdout`; stderr holds only `devenv-stderr`.
  - (b) Standard input is a file holding `question`: `log/claude-stdin` holds `question` and `log/devenv-stdin` is empty.
  - (c) `STUB_CLAUDE_EXIT=7`: `$code` is 7.
  - (d) `COLDLOGIC_DEVENV_SESSION=1` alone: no `log/devenv`; claude ran with its arguments and `session=1`; nothing new in `proj`.
  - (d2) `CLAUDE_CODE_CHILD_SESSION=1` alone: no `log/devenv`; claude ran with `session=1`.
  - (d3) Both, with `CLAUDECODE=1`: no `log/devenv`; `log/claude` has `CLAUDECODE=1`.
  - (e) `CLAUDECODE=1` alone, the IDE terminal: `log/devenv` has `CLAUDECODE=unset` and `session=unset`, and `log/claude` has `CLAUDECODE=1` and `session=1`.
  - (f) Run from `proj/src/deep`: devenv's `cwd` is `proj`, claude's is `proj/src/deep`.
  - (g) `proj` has only `devenv.yaml`: devenv's `cwd` is `proj`.
  - (h) `STUB_GIT_TOP` is a directory with neither file, `DEVENV_ROOT` the case's project, `STUB_DEVENV_EXIT=3`: no `log/devenv`, claude ran in that directory with `session=1`, stderr empty (review fix R2).
  - (i) `STUB_GIT_TOP` unset (git exits 128), the same `DEVENV_ROOT`: the same (review fix R2).
  - (j) git exits 128 and no `DEVENV_ROOT`: no `log/devenv`, claude ran with `session=1`, stderr empty (review fix R2).
  - (k) `STUB_DEVENV_EXIT=3`, `proj/.claude/settings.json` a link to an existing file: claude ran; stderr has `couldn't refresh`, `exited 3` and `may be out of date`.
  - (l) `STUB_DEVENV_EXIT=3`, no settings: `$code` is 1, no `log/claude`, stderr has `not starting claude`, the settings path and `COLDLOGIC_START_WITHOUT_SETTINGS=1 claude`.
  - (m) As (l), with the settings a link to a path that doesn't exist: the same refusal.
  - (n) As (l), with `COLDLOGIC_START_WITHOUT_SETTINGS=1`: claude ran; stderr has `Starting claude anyway`.
  - (o) As (l), with the settings a regular file: claude ran.
  - (p) No `devenv` stub (and `$path` without the outer `PATH`'s devenv: build `$path` from the three case directories and the directory of `command -v timeout` only), settings present: claude ran, stderr has `exited 127`.
  - (q) `STUB_DEVENV_EXIT=0`, no settings: claude ran and the wrapper printed nothing of its own (decision 5: a refresh that succeeds is trusted).
  - (r) `$path` lists `wrap/bin` twice before `real/bin`: `log/claude` has one `ran` line, `log/devenv` one.
  - (s) `link/bin` is a link to `wrap/bin`, and `$path` is `link/bin`, `wrap/bin`, the rest; `$entry` is `link/bin/claude`: claude ran once.
  - (t) A second wrapper installed in `wrap2/bin`; `$path` is `wrap/bin`, `wrap2/bin`, the rest: claude ran once, its `wrappers=` names both wrappers, and `log/devenv` has one `ran` line (the second wrapper sees the first's marker).
  - (u) As (t) with `real/bin` left off `$path`: `$code` is 127, not 124 (the timeout).
  - (v) No `real/bin` on `$path`: `$code` is 127, stderr has `no Claude Code found`, no `log/devenv`.
  - (w) Before `real/bin` on `$path`: a directory holding a non-executable file named `claude`, and one holding a directory named `claude`. Both are skipped and claude ran.
  - (x) `COLDLOGIC_WRAPPERS_RUN` already holds the wrapper's own path and `COLDLOGIC_DEVENV_SESSION=1`, as a session's Bash tool would pass them: claude ran once, with no `log/devenv`.

  Verify: `devenv shell --quiet -- bash packages/claude-wrapper-test.sh packages/claude-wrapper.sh` ends with `0 failed`. Then check the tests bite, undoing each edit after: drop the marker from step 2 and confirm (d) fails; drop `CLAUDE_CODE_CHILD_SESSION` from step 2 and confirm (d2) fails; add `CLAUDECODE` to step 2 and confirm (e) fails; drop `CLAUDECODE` from the `unset` and confirm (e) fails; drop `COLDLOGIC_DEVENV_SESSION` from the `unset` and confirm (a) fails; drop `</dev/null` and confirm (b) fails; drop `>/dev/null` and confirm (a) fails; make `is_wrapper` ignore `$seen` and confirm (u) fails; replace `[ -e "$settings" ]` with `[ -L "$settings" ]` and confirm (m) fails. Finally `devenv shell --quiet -- shellcheck --shell=bash packages/claude-wrapper-test.sh` reports nothing.

## 2. The package and the shell

- [x] 2.1 Create `packages/claude-wrapper.nix`, a function of `{ pkgs }` (decision 7), after `packages/session-relink.nix`:
  - `tested`: `pkgs.runCommand "coldlogic-claude-wrapper-test"` with `nativeBuildInputs = with pkgs; [ bash coreutils ];`, running `bash ${./claude-wrapper-test.sh} ${./claude-wrapper.sh}` and `touch $out`.
  - `app`: `pkgs.writeShellApplication` with `name = "coldlogic-claude-wrapper"`, `runtimeInputs = [ ]`, and `text` made of `# Tested by ${tested}`, then `git_bin=${pkgs.git}/bin/git`, then `builtins.readFile ./claude-wrapper.sh`.
  - The result: `pkgs.runCommand "coldlogic-claude" { }` that makes `$out/bin` and links `$out/bin/claude` to `${app}/bin/coldlogic-claude-wrapper`.
  - A header comment: what it is, that its cases run at build, and why there are no `runtimeInputs` (they would be exported onto the `PATH` every session it starts inherits) and no nix `devenv` (the refresh must use the developer's own).

  Invariant: the package puts one name, `claude`, on `PATH`, and the built script contains no `export PATH`. Verify in 4.1.
- [x] 2.2 In `devenv.nix`, add `claude-wrapper = import ./packages/claude-wrapper.nix { inherit pkgs; };` after the `prune-worktrees` binding (line 10), and add to the developer profile's `packages` (173-180), after `prune-worktrees`:

  ```nix
  # `claude`, ahead of the real one on PATH: refreshes the generated
  # files before it starts a session, and marks that session
  # (packages/claude-wrapper.sh).
  claude-wrapper
  ```

  Verify: `devenv shell --quiet -- devenv build shell` succeeds, which runs 1.2's cases in the Nix build.
- [x] 2.3 In `scripts/check.sh`, in the comment above `step "build: shell"` (106-107), add claude-wrapper's to the build-time tests it lists. Verify by reading the comment.

## 3. One session test in `devenv.nix`

Decision 2. The new test is a superset of the old one, so no step here can make a session run a file task that it skips today. Change only the lines named. `coldlogic:worktree-hooks-path`, `coldlogic:openspec-files`, `coldlogic:setup-freshness` and the body of `coldlogic:generated-files-stale` below its first line belong to the parallel change (design.md, the overlap list).

- [x] 3.1 Replace the `skipInSession` binding and its comment (74-78) with:

  ```nix
  # Inside a Claude Code session: the `claude` wrapper's marker
  # (packages/claude-wrapper.sh), or Claude Code's own variable, for a
  # session the wrapper didn't start (the desktop app, an IDE extension).
  # The one session test in this module: nothing else may decide it, and
  # it must never be narrower than CLAUDECODE alone, or such a session
  # would run devenv's link step in its sandbox (#68).
  inSession = ''{ [ -n "''${COLDLOGIC_DEVENV_SESSION:-}" ] || [ -n "''${CLAUDECODE:-}" ]; }'';
  # The status of devenv's two file tasks: skip (exit 0) in a session,
  # run (exit 1) outside one.
  skipInSession = ''
    ${inSession}
  '';
  ```

  Invariant: the status is the test and nothing after it, since its exit code is the answer: 0 skips the task, 1 runs it. Verify in 4.2.
- [x] 3.2 In `coldlogic:session-files` (526) and `coldlogic:generated-files-stale` (544), replace the line `[ -n "''${CLAUDECODE:-}" ] || exit 0` with `${inSession} || exit 0`. Invariant: `coldlogic:session-files` stays the exact complement of the two statuses, so a shell never runs both linkings or neither. Change nothing else in either task.
- [x] 3.3 In `coldlogic:prune-worktrees` (654), replace `[ -z "''${CLAUDECODE:-}" ] || exit 0` with `if ${inSession}; then exit 0; fi`. Task scripts run under `set -e`, hence the `if`. Invariant: no prune starts inside a session, where the sandbox would deny its removals.
- [x] 3.4 Bring the comments up to date, changing no code. At 53-54, "Only a terminal shell refreshes it." becomes "Only a terminal shell refreshes it, or the `claude` wrapper before a session starts." In the block at 497-511, "which only a terminal shell refreshes" becomes "which only a terminal shell or the `claude` wrapper, before a session starts, refreshes". In the comment above `coldlogic:prune-worktrees` (648-651) nothing names the variable; leave it. Verify: `devenv shell --quiet -- rg -n -e CLAUDECODE -e COLDLOGIC_DEVENV_SESSION devenv.nix` shows the `inSession` binding and its comment only, and `devenv shell --quiet -- rg -n CLAUDECODE packages profiles scripts templates tests` shows only `packages/prune-worktrees-test.sh`'s `unset`, `packages/claude-wrapper.sh` and its test.
- [x] 3.5 Run `devenv shell --quiet -- nixfmt devenv.nix packages/claude-wrapper.nix`, then verify `devenv shell --quiet -- nixfmt --check devenv.nix packages/claude-wrapper.nix` passes and `devenv shell --quiet -- devenv build shell` succeeds.

## 4. Checks from the session

No test runs the tasks, so these are done by hand in this worktree's own shell. Find each generated script with `devenv shell --quiet -- printenv DEVENV_TASK_FILE`, then `jq` on that file for the task's `status` or `command` path, then read it.

- [x] 4.1 Run `devenv shell --quiet -- printenv PATH` and verify the directory of the new `coldlogic-claude` store path comes before the real `claude`'s directory (`/opt/homebrew/bin` on Derek's machine). Read that directory's `claude` (a link to the application) and verify: the line `git_bin=/nix/store/…/bin/git` is there, the wrapper adds nothing to PATH (the `export PATH="$PATH"` that writeShellApplication writes is a no-op), and the `bin` directory holds only `claude`.
- [x] 4.2 Read the generated status scripts of `devenv:files` and `devenv:files:cleanup`. Verify each is only the shared test. Run each four ways with `env -u CLAUDECODE -u COLDLOGIC_DEVENV_SESSION` plus the variables to set, and confirm: `CLAUDECODE=1` alone exits 0; `COLDLOGIC_DEVENV_SESSION=1` alone exits 0; both exit 0; neither exits 1. A status only tests, so running it with the variables cleared is safe; do not run a task's command script that way.
- [x] 4.3 Read the generated command scripts of `coldlogic:session-files`, `coldlogic:generated-files-stale` and `coldlogic:prune-worktrees`. Verify each starts with the shared test, spelled exactly as in the statuses, and that the first two leave at once outside a session and the third inside one.
- [x] 4.4 Run `devenv shell --quiet -- true` and verify the session behaves as before the change: `devenv:files` and `devenv:files:cleanup` are `(cached)`, `coldlogic:session-files` succeeds, and the generated-files notice appears exactly when it did before.
- [x] 4.5 Run `devenv shell --quiet -- claude --version`. In a session this takes the wrapper's nested branch. Verify it prints Claude Code's version, and that `ls -la .claude` and `readlink .mcp.json` show the same as before the call. If the guard asks about the command, say so in the PR and leave the check to 6.1.

## 5. The spec's Purpose and the README

- [x] 5.1 Edit the Purpose of `openspec/specs/generated-files/spec.md` directly (a delta can't carry it) to:

  `How the generated links (`.claude/settings.json`, `.mcp.json`, `.pre-commit-config.yaml` and the rest) are kept current around a Claude Code session, whose sandbox can't safely rewrite them. A session never runs devenv's file tasks or writes the settings link; it relinks the rest atomically and reports what it can't fix. Outside a session, a terminal `devenv shell` refreshes them, and so does the `claude` wrapper before it starts one. A stale link mustn't break the shell or leave the session with no settings (#37, #94, #101).`

  Change nothing else in that file: the requirements change on archive. Verify: `devenv shell --quiet -- openspec validate --all --strict` passes.
- [x] 5.2 In `README.md`, add a "What's here" row after the `packages/prune-worktrees.nix` row, and leave the `devenv.nix` row as it is (the parallel change may edit it):

  `| `packages/claude-wrapper.nix` | `claude`, ahead of the real Claude Code on the developer shell's `PATH`. Outside a session it first refreshes the checkout's generated files (`devenv --quiet tasks run devenv:files`, at the top of the checkout the current directory is in), so every session it starts has current settings; then it starts the real `claude` with the same arguments, directory and streams, and with `COLDLOGIC_DEVENV_SESSION=1`, which marks everything that session runs. The shell counts as inside a session when that marker is set, or Claude Code's `CLAUDECODE` is, for sessions started another way. Inside a session the wrapper only starts `claude`. If the refresh fails it says so, and starts `claude` only when `.claude/settings.json` is there, unless `COLDLOGIC_START_WITHOUT_SETTINGS=1` is set. Its cases in `claude-wrapper-test.sh` run when it builds |`

  Verify by reading the rendered table: one new row, no other row changed.
- [x] 5.3 In `README.md`, add a section `## Starting Claude Code` after "Using it", saying, in short sentences:
  - Start `claude` from the devenv shell (`devenv shell` or direnv), in the checkout. The wrapper refreshes the generated files first, so there is no need to enter a shell and restart sessions after a module update: restart `claude`.
  - Every `claude` command outside a session waits for that refresh, `claude --version` included. It prints nothing unless the refresh fails.
  - It only works where the shell's `PATH` is used. The IDE extension's own launch and the desktop app don't go through it: for those, enter the shell from a terminal once, as before.
  - Start it in the checkout whose settings it should read. In a subdirectory the checkout's files are refreshed, but Claude Code looks for `.claude/settings.json` where it starts.
  - The refresh uses the profile `devenv.yaml` selects, whatever `--profile` the shell was entered with.
  - `COLDLOGIC_DEVENV_SESSION` marks a session. If a terminal has it (`printenv COLDLOGIC_DEVENV_SESSION`), it was opened from inside a session, and neither `claude` nor `devenv shell` refreshes there: open a fresh terminal.
  - A `claude` run inside a session that the wrapper didn't start is recognised through `CLAUDE_CODE_CHILD_SESSION`, which needs Claude Code 2.1.172 or later.
  - A session that started without the settings and is still open can remove the link again (#100): close it.
  - The failure behaviour and `COLDLOGIC_START_WITHOUT_SETTINGS=1 claude`.
  - To run the real binary without the wrapper, take its path from `type -a claude`.

  Verify: every command and variable the section names is spelled as the script and this change's specs spell it.
- [x] 5.4 Run `devenv shell --quiet -- openspec validate claude-wrapper --strict` and verify it reports the change valid.

## 6. Checks from a terminal (Derek, before merge)

The session can't make these: they need a shell outside any session. Each records its result in the PR. A failure of 6.1 to 6.3 goes back to design.md before the merge.

Archived with 6.1 to 6.8 open by design: they are Derek's manual terminal checks, recorded in the PR rather than ticked here.

- [ ] 6.1 Cost. In the main checkout's devenv shell, run `time claude --version` three times, then once more after `touch devenv.nix`. Record the warm and the after-change times. Verify the warm time is acceptable; if it is over two seconds, stop and raise design.md's open question 1.
- [ ] 6.2 `PATH` under direnv. In a fresh terminal, `cd` into the checkout (direnv loads) and run `type -a claude`. Verify the first entry is the `coldlogic-claude` store path and the real one follows.
- [ ] 6.3 The refresh is real, and stays in its checkout. In a worktree with no `.claude/settings.json`, reached by `cd` from the main checkout's `devenv shell` (so `DEVENV_ROOT` is the main checkout), note `readlink` of the main checkout's `.claude/settings.json` and the time of its `.devenv` state's `files.json`, then run `claude --version`. Verify the worktree's `.claude/settings.json` now links into the store, and the main checkout's link and `files.json` are unchanged.
- [ ] 6.4 A stale link. Point the checkout's `.claude/settings.json` at another store file (`ln -sfn`), run `claude --version`, and verify the link is back on the current path.
- [ ] 6.5 The marker. Start `claude` from the shell and have it run `printenv COLDLOGIC_DEVENV_SESSION CLAUDECODE CLAUDE_CODE_CHILD_SESSION` (expect all three) and `devenv shell --quiet -- true` (expect both file tasks `(cached)`). If agent teams are in use, check a teammate has the marker too.
- [ ] 6.6 An IDE terminal. In an IDE extension's terminal, run `printenv CLAUDECODE COLDLOGIC_DEVENV_SESSION CLAUDE_CODE_CHILD_SESSION` (expect only the first), repeat 6.4 there, and verify the link is refreshed.
- [ ] 6.7 Failure. Add a syntax error to `devenv.nix` and run `claude --version`: verify the warning and that it starts. Move `.claude/settings.json` aside and run it again: verify the refusal, exit code 1, and that `COLDLOGIC_START_WITHOUT_SETTINGS=1 claude --version` starts. Restore both.
- [ ] 6.8 The terminal prune still runs. Enter `devenv shell` from a terminal in a project with a merged, idle worktree, and verify it is removed shortly after, as `worktree-cleanup` says.

## 7. Gate

- [x] 7.1 Run `devenv shell --quiet -- scripts/check.sh` and verify it ends with `check: all passed`.

## 8. Review fixes (after archive)

- [x] R1 The refresh unsets every `DEVENV_` variable of the shell it runs in, so devenv works out the project from its directory. Test (g3): the stand-in devenv records `DEVENV_ROOT`, `DEVENV_DOTFILE`, `DEVENV_STATE`, `DEVENV_PROFILE` and `DEVENV_RUNTIME`, and all are unset; claude keeps them.
- [x] R2 No fallback to `DEVENV_ROOT`: outside a devenv project (a git checkout without `devenv.nix` or `devenv.yaml`, or no checkout) the wrapper starts `claude` at once, with no refresh, no settings check and no message. Tests (h), (i), (j).

## Workflow follow-up

- Whichever of this change and `session-fresh-worktrees` lands second adapts to the first: the shared session test in that change's new shell logic, the first line of `coldlogic:generated-files-stale`, and the copy of "A session never writes the settings link" (design.md, the overlap list).
- Archive the change on the feature branch as the last commit before the PR merges.
