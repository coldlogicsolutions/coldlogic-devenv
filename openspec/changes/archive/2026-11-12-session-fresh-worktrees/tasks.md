# Tasks

Run every tool through `devenv shell --quiet -- <cmd>`, one plain command per call. Until group 3 is done, the shell in this worktree prints failed tasks (`coldlogic:worktree-hooks-path`, `devenv:git-hooks:install`, `devenv:enterShell`); the command still runs. Design references are to design.md's numbered decisions. A result different from the one a task lists means the implementation differs from the design: fix the code, not the expectation, or stop and ask.

## 1. The session script: `own-checkout`, `notice`, `clear`

- [x] 1.1 Create `packages/session-shell.sh` with a header comment giving the usage table from decision 1, and this frame: `#!/usr/bin/env bash`, `set -euo pipefail` (the package adds the same, so every command that may fail is guarded with `if`, `||` or `&&`; no ERR trap), a `usage` function that prints one usage line on stderr and exits 2, an `in_session` function whose body is `[ -n "${CLAUDECODE:-}" ]`, and a final `case "${1:-}"` dispatching `own-checkout`, `notice`, `clear`, `skip-hooks-install`, `hooks-check` to functions, with `*) usage`. Leave the two hooks functions as stubs that exit 1 and 0 until group 2. `in_session` is the script's only session test (decision 1): comment it as the one place to change when the `claude-wrapper` change (#101) lands, and never read `CLAUDECODE` anywhere else in the script. If #101 has already merged when this is implemented, give `in_session` the same condition as its `inSession` binding in `devenv.nix` (`[ -n "${COLDLOGIC_DEVENV_SESSION:-}" ] || [ -n "${CLAUDECODE:-}" ]`) and add a case to 1.5 with only `COLDLOGIC_DEVENV_SESSION` set. Verify: `devenv shell --quiet -- shellcheck --shell=bash packages/session-shell.sh` reports nothing, and `devenv shell --quiet -- bash packages/session-shell.sh nope` exits 2.
- [x] 1.2 Implement `own-checkout` (decision 4). Exit 0 when `in_session` is false, `${COLDLOGIC_SESSION_ROOT:-}` is empty or `${DEVENV_ROOT:-}` is empty. Otherwise resolve each with `(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P)` (an inherited `CDPATH` would make `cd` print and corrupt the path); exit 0 if either fails; exit 10 only when both resolve and the two strings differ; else exit 0. Exit 10, not 1, so a helper that fails in any other way is a doubt (8.1). It prints nothing. Invariant: every doubt answers "this is the session's own checkout", so a file that matters is still reported; only a proven other checkout silences a notice. Verify with 1.5's cases (a)-(h).
- [x] 1.3 Implement `notice <key> <text>` and `clear <key>` (decision 5). Both need exactly their arguments, else `usage`. `<key>` must match `^[a-z0-9][a-z0-9-]*$`, else `usage`: this is what keeps a key from naming a path outside the notices directory, so check it before anything touches the filesystem. `notice`: when `in_session` is false, `printf '%s\n' "$text" >&2` and exit 0, touching no file. Otherwise `dir="${DEVENV_STATE:-${DEVENV_ROOT:-.}/.devenv/state}/coldlogic-notices"`, `record="${CLAUDE_CODE_SESSION_ID:--}"$'\n'"$text"`; if `"$(cat -- "$dir/$key" 2>/dev/null || true)" = "$record"`, exit 0 silently; else print the text on stderr first, then try to save: `mkdir -p -- "$dir"`, write `printf '%s\n' "$record"` to `"$dir/.$key.$$"`, `mv -f --` it over `"$dir/$key"`, each with stderr discarded, and on any failure `rm -f` the temporary file; exit 0 whatever happened. `clear`: `rm -f -- "$dir/$key" 2>/dev/null || true`, exit 0. Invariants: the text is printed before any write is tried, so a refused or failed write can't lose it; only an exact match of session and text is silent; nothing here exits non-zero except bad usage. Verify with 1.5's cases (i)-(v).
- [x] 1.4 Create `packages/session-shell.nix`, modelled on `packages/session-relink.nix`: a `tested` derivation (`pkgs.runCommand "coldlogic-session-shell-test"`, `nativeBuildInputs` `bash`, `coreutils`, `findutils`, `git`) running `bash ${./session-shell-test.sh} ${./session-shell.sh}` then `touch $out`; and `pkgs.writeShellApplication { name = "coldlogic-session-shell"; runtimeInputs = [ coreutils git ]; text = "# Tested by ${tested}\n" + builtins.readFile ./session-shell.sh; }`. Header comment: what runs it (the tasks in `devenv.nix` named in decisions 2, 3 and 6) and that its tests gate the build. Verify in 3.1, when the shell first builds it.
- [x] 1.5 Create `packages/session-shell-test.sh`, modelled on `packages/session-relink-test.sh` (`set -eu`, a `mktemp -d` root removed by an EXIT trap that first runs `chmod -R u+w`, `fresh`, `check`, counters, a last line `N passed, M failed` and exit 1 when any failed). Run the script with a clean environment so the caller's session variables can't leak in: `env -i PATH="$PATH" HOME="$root/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null <VAR=value...> bash "$script" <args>`, capturing the exit code, stdout and stderr separately. Skip a case that relies on `chmod a-w` when `id -u` is 0, as session-relink's (d) does. Cases, with `A` and `B` two existing directories:
  - (a) no `CLAUDECODE`, `COLDLOGIC_SESSION_ROOT=A`, `DEVENV_ROOT=B`: exit 0.
  - (b) `CLAUDECODE=1`, no `COLDLOGIC_SESSION_ROOT`, `DEVENV_ROOT=B`: exit 0. (b2) the same with `COLDLOGIC_SESSION_ROOT=` empty: exit 0.
  - (c) `CLAUDECODE=1`, both `A`: exit 0.
  - (d) `CLAUDECODE=1`, `COLDLOGIC_SESSION_ROOT` a symlink to `A`, `DEVENV_ROOT=A/`: exit 0.
  - (e) `CLAUDECODE=1`, `COLDLOGIC_SESSION_ROOT=A`, `DEVENV_ROOT=B`: exit 10.
  - (f) `CLAUDECODE=1`, `COLDLOGIC_SESSION_ROOT=$root/none`, `DEVENV_ROOT=B`: exit 0. (f2) the other way round: exit 0.
  - (g) `CLAUDECODE=1`, `COLDLOGIC_SESSION_ROOT=A`, no `DEVENV_ROOT`: exit 0.
  - (h) in every case above, stdout and stderr are empty.
  - (i) no `CLAUDECODE`, `DEVENV_STATE=S`: `notice k "hello"` twice. Each prints `hello` on stderr, nothing on stdout, exits 0; `S/coldlogic-notices` doesn't exist.
  - (j) `CLAUDECODE=1`, `CLAUDE_CODE_SESSION_ID=s1`, `DEVENV_STATE=S`: first `notice k "hello"` prints `hello`; the second prints nothing; both exit 0.
  - (k) then `notice k "hello two"`: prints; again: silent. Then `notice k "hello"`: prints (the text changed back).
  - (l) then the same text with `CLAUDE_CODE_SESSION_ID=s2`: prints once, then silent.
  - (m) no `CLAUDE_CODE_SESSION_ID`: prints once, then silent; then with `s1`: prints.
  - (n) `clear k`, then the same `notice` as the last silent one: prints. `clear` of a key never written: exit 0, no output.
  - (o) `S` made `chmod a-w` before any record exists: `notice k "hello"` prints on both of two runs and exits 0 both times.
  - (p) a record file that is empty, and one holding only the session line: `notice` prints, and the next run is silent.
  - (q) a two-line text (`$'one\ntwo'`): both lines printed once, then silent.
  - (r) no `DEVENV_STATE`, `DEVENV_ROOT=B`: the record is `B/.devenv/state/coldlogic-notices/k`.
  - (s) usage: `notice` with no arguments, with one, with three; `notice ../x t`; `notice a/b t`; `notice -x t`; `clear ../x`; `clear` with no key: each exits 2, and after `clear ../x` a file placed at `S/x` still exists.
  - (t) after (j)-(q), `find S/coldlogic-notices -name '.*'` finds no temporary file.
  - (u) two keys are independent: after `notice a "t"`, `notice b "t"` prints.
  - (v) another state directory (`DEVENV_STATE=S2`), same session and text: prints.

  Verify: `devenv shell --quiet -- bash packages/session-shell-test.sh packages/session-shell.sh` ends with `0 failed`. Then check the tests bite: temporarily move the `printf ... >&2` after the write block and add `|| exit 0` to the `mkdir`, and confirm (o) fails; temporarily drop the key check and confirm (s) fails. Undo both.

## 2. The session script: `skip-hooks-install`, `hooks-check`

- [x] 2.1 Add the shared helpers. `hooks_dir`: `git -C "$DEVENV_ROOT" rev-parse --path-format=absolute --git-path hooks 2>/dev/null`. `can_write <path>`: walk up with `dirname` while the path doesn't exist, then `[ -w ]` on what is found. `install_blocked <dir> <hook>...`: true only when `in_session` and (`! can_write "$dir"`, or some `"$dir/$hook"` exists and isn't `-w`). The hook list is the subcommand's arguments, or `pre-commit` when there are none. Verify with 2.4's cases.
- [x] 2.2 Implement `skip-hooks-install [<hook>...]` (decision 3): exit 1 when `${DEVENV_ROOT:-}` is empty or `hooks_dir` fails or prints nothing; exit 0 when `install_blocked`; else exit 1. It prints nothing on either stream. Invariant: exit 0 means "skip the install", so every error and every doubt must exit 1, which runs devenv's install as today; outside a session it can never exit 0. Verify with 2.4's (H1), (H2), (H4), (H5).
- [x] 2.3 Implement `hooks-check [<hook>...]` (decision 3), always exiting 0 and printing only through the script's own `notice` function:
  1. `[ -n "${DEVENV_ROOT:-}" ] || exit 0`; `dir=$(hooks_dir) || exit 0`; `[ -n "$dir" ] || exit 0`.
  2. Collect the hooks for which `"$dir/$hook"` isn't a file with `-x` (`[ -f ... ] && [ -x ... ]`).
  3. If there are none, clear `hooks-missing` and exit 0.
  4. Otherwise `notice hooks-missing` with, when `in_session`: `coldlogic: commits here run no <hooks, space-separated> hook: there is none in <dir>, and this Claude Code session can't install one there. Enter the shell once from a terminal, outside a Claude Code session, with: devenv shell.` Outside a session: `coldlogic: commits here run no <hooks, space-separated> hook: there is none in <dir>, and the install didn't add one.`

  Invariants: the script never runs `git config` or writes anything under a git directory: it only reads where git says the hooks are (#67 was a refused git config write, and decision 2 removes every one); a worktree whose commits will run no hook is always told (the silent state `agent-acf80ec4ed5df4a6d` is in); with every expected hook in place nothing is printed. Verify with 2.4.
- [x] 2.4 Add the hooks cases to `packages/session-shell-test.sh`. A helper `mkrepo` makes `main` with `git -c init.defaultBranch=main init`, one empty commit (identity from `GIT_AUTHOR_*`/`GIT_COMMITTER_*` in the environment) and `git worktree add --detach ../wt`. With no hooks path set, `wt` resolves `main/.git/hooks`, as a fresh worktree does. `own_path` sets `extensions.worktreeConfig true` and the worktree's `core.hooksPath` to `main/.git/worktrees/wt/hooks`, as the removed step left older worktrees. `hook <dir> <name>` writes an executable file. Every case uses `DEVENV_ROOT=wt` and a `DEVENV_STATE` of its own unless it says otherwise. Cases (each `chmod a-w` case skipped as root):
  - (H1) session `s1`, an executable `pre-commit` in `main/.git/hooks`, everything writable: `skip-hooks-install pre-commit` exits 1; `hooks-check pre-commit` prints nothing. Neither prints on stdout.
  - (H2) as (H1), then `chmod a-w main/.git/hooks`: `skip-hooks-install` exits 0 with no output; `hooks-check` prints nothing.
  - (H3) as (H2) with no hook in the directory: `skip-hooks-install` exits 0; `hooks-check` prints one line on stderr containing `run no pre-commit hook`, `<main>/.git/hooks` and `devenv shell`; a second run prints nothing. The same with a `pre-commit` that isn't executable. Then, with the hook added (restore the mode, add it, `chmod a-w` again), a run prints nothing and the `hooks-missing` record is gone; with it removed again, the line is printed again.
  - (H4) no `CLAUDECODE`, with (H3)'s layout: `skip-hooks-install` exits 1; `hooks-check` prints, on each of two runs, a line containing `the install didn't add one` and not `Claude Code`, and records nothing.
  - (H5) `skip-hooks-install` in session `s1`: hooks directory missing under a writable parent: 1; missing under a `chmod a-w` parent: 0; directory writable but an existing `pre-commit` `chmod a-w`: 0; `DEVENV_ROOT` outside any repository: 1; no `DEVENV_ROOT`: 1; no arguments behaves as `pre-commit`. No case prints anything.
  - (H6) `hooks-check pre-commit pre-push` with (H2)'s layout and only `pre-commit` present: the line names `pre-push` and not `pre-commit`.
  - (H7) session `s1`, `own_path`, the worktree's own hooks directory absent, an executable `pre-commit` in `main/.git/hooks`: `skip-hooks-install` exits 1 (its parent is writable); `hooks-check` prints a line naming `<main>/.git/worktrees/wt/hooks`. With an executable `pre-commit` created there and none in `main/.git/hooks`: `hooks-check` prints nothing.
  - (H8) `hooks-check` with `DEVENV_ROOT` a directory outside any repository, and with no `DEVENV_ROOT`: exit 0, no output. With no arguments it behaves as `pre-commit`.
  - (H9) nothing writes git config: copy `main/.git/config` before (H1)-(H3) on a fresh `mkrepo`, and after them it is byte-identical (`cmp`) and `main/.git/worktrees/wt/config.worktree` doesn't exist. After (H7), `config.worktree` is byte-identical to what `own_path` left.

  Verify: `devenv shell --quiet -- bash packages/session-shell-test.sh packages/session-shell.sh` ends with `0 failed`, and `shellcheck --shell=bash` passes on both files. Then check the tests bite: temporarily make `hooks-check` test `-e` in place of `-x` and confirm (H3)'s non-executable case fails; temporarily make `in_session` always true and confirm (H4) and 1.5's (a) and (i) fail. Undo both.

## 3. Wire the hooks into `devenv.nix`

- [x] 3.1 Beside the other package imports (devenv.nix:7-10) add `session-shell = import ./packages/session-shell.nix { inherit pkgs; };`. In the developer module's `let`, add `sessionShell = "${session-shell}/bin/coldlogic-session-shell";` and the hooks devenv's install expects, computed as devenv does (`src/modules/integrations/git-hooks.nix` at the locked rev):

  ```nix
  # The hooks devenv:git-hooks:install installs, worked out as devenv does.
  expectedHooks =
    let
      stages = config.git-hooks.installStages or [ ];
      hookName =
        stage:
        if stage == "manual" then
          null
        else if builtins.elem stage [ "commit" "merge-commit" "push" ] then
          "pre-${stage}"
        else
          stage;
    in
    lib.unique (
      if stages == [ ] then [ "pre-commit" ] else builtins.filter (hook: hook != null) (map hookName stages)
    );
  ```

  Verify: `devenv shell --quiet -- devenv build shell` succeeds, which builds the package and runs its tests.
- [x] 3.2 Delete `tasks."coldlogic:worktree-hooks-path"` and the comment above it (devenv.nix:471-495), whole (decision 2). Nothing else names the task. Add nothing that writes git config. Invariant: the shell must not write `core.hooksPath`, `extensions.worktreeConfig` or any other git config, and must not unset a hooks path an earlier shell wrote. Verify: `grep -n "hooksPath" devenv.nix` and `grep -n "worktree-hooks-path" devenv.nix` each find nothing.
- [x] 3.3 In its place add the install's status (decision 3):

  ```nix
  # Hooks live in the hooks directory git resolves, which worktrees share
  # (the main checkout's `.git/hooks`). Since devenv's change of 2026-10-19
  # the hook there names its configuration by a relative path, so it reads
  # the committing worktree's own; the module needs a devenv at least that
  # new, and no longer gives each worktree a hooks path (#67).
  #
  # In a session, the install is skipped where it can't write that
  # directory, which the sandbox protects. Exit 0 skips; any error exits
  # non-zero, which runs the install as devenv defines it.
  tasks."devenv:git-hooks:install".status = lib.mkIf config.git-hooks.enable ''
    ${sessionShell} skip-hooks-install ${lib.escapeShellArgs expectedHooks}
  '';
  ```

  Invariant: nothing but the script's exit code decides it, and the script can exit 0 only inside a session with an unwritable hooks directory, so a terminal shell always installs. The call must be the status's last command. Verify in 6.1.
- [x] 3.4 Below it add the missing-hook check (decision 3):

  ```nix
  # A status prints nothing, so this says when commits here will run no
  # hook: the install was skipped, or didn't add one. Silent when every
  # expected hook is in place. Never fails.
  tasks."coldlogic:hooks-check" = lib.mkIf config.git-hooks.enable {
    exec = ''
      ${sessionShell} hooks-check ${lib.escapeShellArgs expectedHooks} || true
      exit 0
    '';
    after = [ "devenv:git-hooks:install" ];
    before = [ "devenv:enterShell" ];
  };
  ```

  Invariant: this task is a dependency of `devenv:enterShell`, so it must exit 0 whatever happens, a missing binary included. Verify in 6.1 and 6.2.
- [x] 3.5 In `claude.code.env` (devenv.nix:187-197) add, with a comment, `COLDLOGIC_SESSION_ROOT = config.devenv.root;`: the checkout these settings were generated for, which a session carries into every command, so a shell it enters elsewhere knows the session reads its settings, `.mcp.json` and skills from here (decision 4). Verify in 6.1 by reading the generated settings file.
- [x] 3.6 Run `devenv shell --quiet -- nixfmt devenv.nix packages/session-shell.nix`, then verify `devenv shell --quiet -- nixfmt --check devenv.nix packages/session-shell.nix` passes.

## 4. Wire the notices into `devenv.nix`

- [x] 4.1 In the developer module's `let`, add the notice wrapper and the links compared in another session's checkout:

  ```nix
  # notice <key> <text>: once per session (packages/session-shell.sh), and
  # printed anyway if the helper fails. forget <key>: when the condition is gone.
  noticeFunctions = ''
    notice() { ${sessionShell} notice "$1" "$2" || echo "$2" >&2; }
    forget() { ${sessionShell} clear "$1" || true; }
  '';
  # The generated files only a session started in this checkout reads. A
  # session that reads them from another checkout isn't told about these.
  sessionOnlyFiles = [
    config.claude.code.settingsPath
    ".mcp.json"
  ];
  otherLinks = removeAttrs generatedLinks sessionOnlyFiles;
  ```

  Invariant: a notice is never lost to the helper: if the binary is missing or exits non-zero, the text is echoed. Verify: `devenv shell --quiet -- devenv build shell` still succeeds.
- [x] 4.2 In `coldlogic:generated-files-stale` (devenv.nix:542-590), after the `cd`: insert `${noticeFunctions}`, then `own=0` and `${sessionShell} own-checkout || own=$?`. Replace the single comparison with: when `[ "$own" = 10 ]`, capture `sessionRelink [ "--check-only" "--print" ] otherLinks`; otherwise capture it over `generatedLinks`, as now; both with `|| code=$?`. Replace the two `echo ... >&2` lines with `notice generated-files-check "<text>"` and `notice generated-files "<text>"`, building each text in a variable first. Add `forget generated-files-check` once `code` is 0 or 1, and `forget generated-files` when `code` is 1 or `out` is empty. In the notice text, replace `this one included, since a running session can undo the refresh.` with `this one included, before any of them runs another command, since a running session can undo the refresh at its next tool call.` and change nothing else in it. Keep the session test as the `exec`'s first line and don't reword it: the `claude-wrapper` change (#101) replaces that line with `${inSession} || exit 0`, and whichever change lands second keeps #101's form there with this task's body after it. Keep `--check-only`, the kinds, the `%q` quoting, `exit 0` and the orderings. Update the comment above the task: the notice is printed once per session, and leaves out the settings link and `.mcp.json` where the session reads them from another checkout. In the Nix string write each shell `${` as `''${`. Invariants: any `own` but 10 compares everything, so a doubt reports; the task still only compares, and never fails. Verify in 6.1 and 6.2.
- [x] 4.3 In `coldlogic:openspec-files` (devenv.nix:683-721), after the `cd`: insert `${noticeFunctions}`, then

  ```sh
  own=0
  ${sessionShell} own-checkout || own=$?
  [ "$own" != 10 ] || exit 0
  ```

  No session test wraps it: `own-checkout` exits 10 only inside a session (1.5's case (a)), and the script holds the one session test (decision 1).

  Add `forget openspec-files` before the `exit 0` taken when the stamp matches, and after the stamp is written on success. Replace the "may be out of date" `echo` with `notice openspec-files "<same text>"`. Replace the "couldn't generate" `echo` and the `printf ... | grep -m1 '^Failed'` after it with: `detail=$(printf '%s\n' "$out" | grep -m1 '^Failed' || true)`, then `notice openspec-files "<same text>''${detail:+$'\n'$detail}"`. Update the comment above the task: a session that reads its skills from another checkout generates nothing and says nothing; the warning is printed once per session. Invariant: only `own` = 10 skips generation, so a terminal shell and the session's own checkout behave as before. Verify in 6.1 and 6.2.
- [x] 4.4 In `coldlogic:setup-freshness` (devenv.nix:595-646), insert `${noticeFunctions}` after the `export PATH`, replace the final `echo "coldlogic-devenv is behind ..." >&2` with `notice freshness "<same text>"`, and add an `elif [ -n "$latest" ]; then forget freshness` branch. Verify: `devenv shell --quiet -- devenv build shell` succeeds; this repository has no `coldlogic-devenv` lock node, so the task exits before the notice here, and the text is checked by reading the generated script in 6.1.
- [x] 4.5 Run `devenv shell --quiet -- nixfmt devenv.nix` and verify `devenv shell --quiet -- nixfmt --check devenv.nix` passes.
- [x] 4.6 Check the session test is in one place (decision 1; the `claude-wrapper` change, #101, depends on it). Verify: `git diff origin/main -- devenv.nix` adds no line holding `CLAUDECODE`, and `grep -n CLAUDECODE packages/session-shell.sh` shows it only in `in_session` and the comment above it.

## 5. The guard: deny a tracking branch create

Run the guard's cases with `devenv shell --quiet -- python3 -I packages/claude-guard-test.py`. It prints `N/N passed` and exits 0 when every case passes.

- [x] 5.1 In `packages/claude-guard.py`, after `names_ref`, add `remote_branch(gitdir, name)`: False when `name` is empty, ends with `/`, holds `..` or `@{`, or matches `[\s~^:?*\[\\]`. Otherwise, with `packed = packed_refs(gitdir)`, True when for `ref` in (`refs/remotes/` + name, `refs/` + name, name) the ref starts with `refs/remotes/`, is longer than that prefix, and `has_ref(gitdir, ref, packed)` or `has_ref(gitdir, ref + "/HEAD", packed)`. Docstring: whether name is a remote-tracking branch, loose or packed, in the spellings git takes (`origin/main`, `remotes/origin/main`, `refs/remotes/origin/main`, or a remote alone); a local branch of the same name isn't looked for, so such a name is over-reported. Verify with 5.4.
- [x] 5.2 After `leaves_branch`, add `sets_upstream(sub, args, gitdir)`, returning `(new branch or None, start point or None)` when the command would write tracking configuration, else None (decision 7). Parse `args` in one pass, as `leaves_branch` does:
  - `--` ends the options for `checkout` (stop); for `switch` it is skipped.
  - A word starting `--`: split at the first `=`. `long_option(w, "--no-track", 6)` sets `track = False`; else `git_option(w, "--track")` sets `track = True`. `git_option(w, "--detach")` or `git_option(w, "--orphan")` sets `none_made = True`. For `switch`, `git_option` on `--create` or `--force-create` takes the new branch's name from after the `=`, or else from the next word (consume it). Any other of `--orphan`, `--conflict` and, for `checkout`, `--pathspec-from-file`, given without `=`, consumes the next word.
  - A short cluster (starts `-`, isn't `-`): for each letter in turn, `c`/`C` (`switch`) or `b`/`B` (`checkout`) takes the rest of the word as the new branch's name, or the next word when nothing is left (consume it), and ends the cluster; `t` sets `track = True`; `d` sets `none_made = True`; a non-alphanumeric character ends the cluster.
  - Anything else is an operand.

  Then: None when `none_made` or `track is False`; `(new, start)` when `track` is True, with `start` the first operand or None; `(new, start)` when a new branch was named, there is a first operand, and `remote_branch(gitdir, start)`; else None. The later tracking option wins because each one overwrites `track`. Verify with 5.4.
- [x] 5.3 After `main_checkout_switch`, add `tracking_create(result)`, shaped like it: None without `WORKING["cwd"]`; for each command (skipping calls to functions the call defines, as it does), `git_place(words, result.moved.get(id(words), WORKING["cwd"]))`; skip when it is None, the subcommand isn't `switch` or `checkout`, or the directory is None. Find `main = main_checkout()` once (None: return None). `top = repo_top(here)`; skip when None; when `top != main`, skip unless `linked_git_dirs(top)` gives a common directory equal to `os.path.realpath(os.path.join(main, ".git"))`. Call `sets_upstream(sub, args, os.path.join(main, ".git"))`; on a result return `("deny", reason)` where the reason is ``coldlogic guard: this `git {sub}` would set up tracking{ of <start>}, which writes .git/config. The sandbox protects that file, so the command would fail partway. Add --no-track{: `git switch --no-track -c <new> <start>`}.`` (the first braces only with a start point, the second only with both a new branch and a start point). In `decide`, inside the `try`, right after the `if stray and stray[0] == "deny": return stray` lines, add `tracked = tracking_create(result)` and return it when set. Add a bullet to the module docstring's list. What it protects: the shared `.git/config`, which the sandbox denies; without the deny the command fails after creating the branch and before checking it out (#45). It is a deny-side check, so it may over-report (a shadowing local branch, `autoSetupMerge=false`) and must never turn a deny or an ask into an allow: it only ever returns a deny or None. Verify with 5.4.
- [x] 5.4 In `packages/claude-guard-test.py`, in the "main checkout stays on main" block: add `open(os.path.join(root, ".git", "refs", "remotes", "origin", "main"), "w").close()` beside the `site` ref (the fixture already has a loose `origin/site` and a packed `origin/wip`). Before changing the guard, run the three commands marked "as before" below in `sib` and note the decision each gets. Change four expectations in the #44 loop from `"allow"` to `"deny"`: `git switch -c feat/x origin/main`, `git switch --create feat/x origin/main`, `git switch --track -c feat/x origin/main`, `git switch -C feat/x origin/main`; and reword that loop's comment (`--track` and a tracking start are denied; `-C` is judged as before otherwise). Add to the same loop, so each runs in `sib` and `nested` from both session roots:
  - deny: `git switch -c feat/x origin/wip`, `git switch -c feat/x origin/site`, `git switch -cfeat/x origin/main`, `git switch -qc feat/x origin/main`, `git switch --cr feat/x origin/main`, `git switch --create=feat/x origin/main`, `git switch -c feat/x refs/remotes/origin/main`, `git switch -c feat/x remotes/origin/main`, `git switch -t origin/site`, `git switch --track origin/site`, `git switch --tr origin/site`, `git switch --no-track --track -c feat/x origin/main`, `git switch -c feat/x --track main`, `git checkout -b feat/x origin/main`, `git checkout -B feat/x origin/main`, `git checkout -tb feat/x origin/main`, `git checkout --track origin/site`, `git fetch origin main && git switch -c feat/x origin/main`, `devenv shell --quiet -- git switch -c feat/x origin/main`, `bash -c 'git switch -c feat/x origin/main'`.
  - allow: `git switch --track --no-track -c feat/x origin/main`, `git switch -c feat/x origin/gone`, `git switch -c feat/x docs` (a local branch in the fixture).
  - as before (the decision noted above, which must not be `deny`): `git switch -c feat/x origin/main~1`, `git switch --orphan feat/x`, `git checkout --no-track -b feat/x origin/main`.
  - None (`git checkout` has no allow rule): `git checkout -b feat/x`, `git checkout origin/main -- README.md`.

  Add to the main list, with `policy`: `(root, f"git -C {sib} switch -c feat/x origin/main", "deny")`, `(sib, "cd packages/foo && git switch -c feat/x origin/main", "deny")`, `(os.path.join(root, "vendor", "lib"), "git switch -c feat/x origin/main", None)`, and confirm the existing `(root, "git switch --no-track -c feat/x origin/main", "deny")` still passes. After the loop add two message checks: with `cwd=sib`, `git switch -c feat/x origin/main` gives a reason containing `--no-track` and `git switch --no-track -c feat/x origin/main`; with `cwd=root`, the same command's reason starts with `guard.MAIN_CHECKOUT` (the main checkout's deny comes first). Verify: the run prints `N/N passed`. Then check the tests bite: temporarily make `remote_branch` return False and confirm the `origin/main` cases fail; temporarily stop `--no-track` from setting `track = False` and confirm the `--no-track` cases fail. Undo both.
- [x] 5.5 In `README.md`, in the `packages/claude-guard.py` row, after the sentence ending `and the forced forms ask.`, add: in the project's repository a `git switch` or `git checkout` that would set up tracking (`--track` or `-t`, or a new branch from a remote-tracking start point without `--no-track`) is denied with a pointer to `--no-track`, since the sandbox protects `.git/config`. Verify: the row reads correctly in `git diff README.md`.

## 6. Check the generated scripts and the shell

No test runs the tasks, so these are done by hand in this worktree, an EnterWorktree worktree whose shell uses this `devenv.nix`. Find each script with `devenv shell --quiet -- printenv DEVENV_TASK_FILE`, then read that file for the task's `status` or `command` path, then read the script. This session started before this change, so it has no `COLDLOGIC_SESSION_ROOT`: here `own-checkout` exits 0 and the session-only files are still reported, once.

- [x] 6.1 Read the generated scripts. Verify: there is no `coldlogic:worktree-hooks-path` task; `devenv:git-hooks:install` has a status that is only the `skip-hooks-install pre-commit` call; `coldlogic:hooks-check` is the `hooks-check pre-commit` call, `|| true`, `exit 0`, ordered after the install; `coldlogic:generated-files-stale` has two comparisons, one with the absolute settings path and `.mcp.json` and one with neither, and prints only through `notice`; `coldlogic:openspec-files` and `coldlogic:setup-freshness` print only through `notice`. Copy the hooks-check script to `$TMPDIR`, replace the binary's path with one that doesn't exist, and confirm it exits 0. Copy the generated-files-stale script, replace the `coldlogic-session-shell` path with one that doesn't exist (not `false`: its exit 1 would once have meant "another checkout"), run it with `CLAUDECODE=1` and `DEVENV_ROOT` set to this worktree, and confirm the notice is still printed (the `echo` fallback) and it exits 0. Read the settings file devenv built (the store path the settings link would name, from the generated `devenv:files` script) and confirm `.env.COLDLOGIC_SESSION_ROOT` is this worktree's root.
- [x] 6.2 Run `devenv shell --quiet -- true` twice in this worktree. Verify on the first run: no task fails, `devenv:git-hooks:install` is skipped, `coldlogic:hooks-check` runs after it (so a task ordered after a skipped one still runs; design.md, Assumed) and `devenv:enterShell` runs; exactly two `coldlogic:` notices appear (the generated files, with the new restart wording; the OpenSpec skills), and nothing about hooks, since `<main>/.git/hooks` holds `pre-commit`. Verify on the second run: no `coldlogic:` line at all. Verify `git config --worktree --get core.hooksPath` still prints `<main>/.git/hooks`, `coldlogic-notices/` under `$DEVENV_STATE` holds two records whose first line is this session's id, and `printenv CLAUDE_CODE_SESSION_ID` prints it. Then run the built `coldlogic-session-shell hooks-check pre-commit` with `DEVENV_ROOT` set to a directory under `$TMPDIR` holding a fresh `git init` and confirm it prints the missing-hook notice naming that repository's `.git/hooks`.
- [x] 6.3 From 6.2's first run, record whether the notices were visible although every task succeeded under `--quiet` (design.md, Assumed). If they were not, don't change the design: say so in the PR description and stop for a decision.
- [x] 6.4 In `README.md`: in the `devenv.nix` row, replace `per-worktree \`core.hooksPath\`` with: worktrees share the hooks git resolves, a session skips a hook install it can't write, and a missing hook is reported. In "Using it", after the paragraph on the inputs the project declares, add one sentence: the project's `devenv.lock` must pin a devenv from 2026-10-19 or later, since worktrees share one hooks directory and only from then does the installed hook read the committing worktree's own configuration. And add a row after `packages/prune-worktrees.nix` for `packages/session-shell.nix`: `coldlogic-session-shell`, what a shell does differently inside a Claude Code session (whether the hook install is skipped, the missing-hook notice, whether this checkout is the one the session reads its Claude Code files from, and each notice once per session), with its cases in `session-shell-test.sh` run when it builds. Verify: `git diff README.md` shows only these rows and 5.5's.
- [x] 6.5 Run `devenv shell --quiet -- openspec validate session-fresh-worktrees --strict` and verify it reports the change valid.

## 7. Gate

- [x] 7.1 Run `devenv shell --quiet -- scripts/check.sh` and verify it ends with `check: all passed`.

## 8. Verification fixes

- [x] 8.1 Make "another checkout" exit 10 (decision 4), so a helper that fails any other way, a crash with exit 1 included, is a doubt and everything is reported. In `packages/session-shell.sh`, `own_checkout` exits 10 where it exited 1, and its comment and the header's usage table say so. In `devenv.nix`, `coldlogic:generated-files-stale` tests `[ "$own" = 10 ]` and `coldlogic:openspec-files` `[ "$own" != 10 ] || exit 0`; update their comments. Case (e) in `session-shell-test.sh` expects 10. Verify: `grep -n 'own" [!=]*= 1\b' devenv.nix` finds nothing, and the build's tests pass.
- [x] 8.2 Show that only 10 silences. Copy the generated `coldlogic:generated-files-stale` script to `$TMPDIR` and replace the `coldlogic-session-shell` path with `false`. Run it with `CLAUDECODE=1` and `DEVENV_ROOT` set to this worktree, and confirm it compares everything: the notice names the settings link or `.mcp.json` where either is missing, and it exits 0. Repeat with a stub that exits 10, and confirm neither is named. Record both in the PR's test plan.
- [x] 8.3 In `packages/claude-guard-test.py`, add `git switch -c feat/x main` to the #44 loop's allow list (the spec's "A start point that sets up no tracking" names it). Verify: the guard tests print `N/N passed`.
- [x] 8.4 Run `devenv shell --quiet -- scripts/check.sh` and verify it ends with `check: all passed`.
- [x] 8.5 Review fix: `notice` reads its record back with `$(cat)`, which drops trailing newlines, so a text ending in one never matched and was printed on every shell. At the start of `notice`, after the key check and before printing or building the record, drop the text's trailing newlines. Add case (q2) to `session-shell-test.sh`: a text ending in `\n\n` prints once as one line, is then silent, and the same text without the newlines is silent too. Verify: the build's tests pass, and with the strip disabled (q2) fails.
- [x] 8.6 Review fix: when every enabled hook is manual-stage, `expectedHooks` is empty and devenv installs no hook, but `hooks-check` with no hooks falls back to `pre-commit` and reported it missing on every terminal shell. In `devenv.nix`, add `hooksExpected = config.git-hooks.enable && expectedHooks != [ ]` and define the install's status and `coldlogic:hooks-check` only under `lib.mkIf hooksExpected`, with a comment saying why; devenv's install is untouched. Add the "No hook expected" scenario to the git-hooks spec (this change's delta and `openspec/specs/git-hooks/spec.md`). Verify: the shell builds, and the gate passes.

## Workflow follow-up

- Archive the change on the feature branch as the last commit before the PR merges. After archiving, run `openspec validate --all --strict`: the main specs' requirement text must stay within the length limit.
- File the manual checklist below as the #64 follow-up issue, close #64 as superseded by it, and replace "the #64 follow-up" in `openspec/specs/session-permissions/spec.md` with the issue's number.

### Manual checklist (Derek, after merge; the #64 follow-up)

- A. In a terminal on updated main, run `devenv shell`, then restart every session.
- B. From a new session, in a worktree made for a subagent with `isolation: worktree`:
  - `devenv shell --quiet -- true` exits 0 with `devenv:enterShell` succeeding, `devenv:git-hooks:install` skipped, and no `coldlogic:` notice; a second run prints none either.
  - After that first shell, `git rev-parse --git-path hooks` names `<main>/.git/hooks`, which holds an executable `pre-commit`, and the worktree's `config.worktree` is as the harness made it (compare its modification time with the worktree's creation).
  - `git status`, `git log --oneline -3` and `git switch --no-track -c probe/x origin/main` run without prompts. `git switch -c probe/y origin/main` is denied, and the reason names `--no-track`.
  - `.mcp.json` and `.pre-commit-config.yaml` are links. There is no `.claude/settings.json` and nothing under `.claude/skills`, and nothing was printed about either.
  - Hooks fire, through the main checkout's hook with this worktree's configuration: a commit of a misformatted `.nix` file is rejected.
  - `touch .devenv/probe` works.
- C. Repeat B in a worktree entered with EnterWorktree. The one expected difference: `.mcp.json` doesn't exist there (the sandbox protects it), and nothing was printed about it.
- D. In a worktree made before this change that still has its own `core.hooksPath` (if one is left): `devenv shell --quiet -- true` exits 0; afterwards either its own hooks directory holds an executable `pre-commit`, or one `coldlogic:` notice named that directory.
- E. Clean up (the probe branches and worktrees), and report the results on the issue.
