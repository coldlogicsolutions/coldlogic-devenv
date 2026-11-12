# Tasks

Run every tool through `devenv shell --quiet -- <cmd>`. In a session the shell may print failed tasks (`devenv:git-hooks:install`, `devenv:enterShell`); the command still runs. Design references are to design.md's numbered decisions.

## 1. The relink script: drop `--state`, add kinds to `--print`

- [x] 1.1 In `packages/session-relink.sh`, remove the `--state` option (decision 2): its `case` arm, the `state` variable, the `respells` function, the whole `if [ -n "$state" ] && [ -e "$state" ]` block, and the `skip` variable. The final test becomes: exit 0 when `stale` is non-empty, else exit 1. Keep `set -eEuo pipefail`, the ERR trap (exit 3), `usage` (exit 2), `abandoned` and `sweep` exactly as they are. Invariant: the script never removes or replaces a link at a `<path>` except by renaming a new link over it; its only `rm` calls stay the two on its own temporary links. Verify: `rg -n -e '--state' -e respells -e realpath -e jq packages/session-relink.sh` finds nothing, and `rg -n 'rm -f' packages/session-relink.sh` shows two lines, both on `"$old"` or `"$tmp"`.
- [x] 1.2 In the same file, make `--print` print a kind with each path (decision 5). Add an array `kinds=()` beside `stale=()`. In the main loop, after the two `continue` checks (current link; real file) and before the `check_only`/directory test, set `kind=stale` and then `[ -L "$f" ] || kind=missing`. At both places that do `stale+=("$f")`, also do `kinds+=("$kind")`. Replace the final `printf '%s\n' "${stale[@]}"` with a loop printing `"${kinds[i]} ${stale[i]}"`, one per line. Invariant: the kind is read before any relink attempt, and a failed attempt leaves the path unchanged, so the printed kind is true. Verify with 1.4's tests (v) and (v2).
- [x] 1.3 Rewrite the header comment of `packages/session-relink.sh`: it is now run by the `coldlogic:session-files` task and by `coldlogic:generated-files-stale`, no longer by the two statuses; usage is `coldlogic-session-relink [--check-only] [--print] [--] <path> <target> ...`; `--print` prints `missing <path>` or `stale <path>`; exits 1 when nothing is stale, 0 when something is, 2 on bad usage, 3 when a command fails; needs GNU coreutils and findutils. Remove every sentence about `--state`, cleanup, `realpath` and "Callers must run the task only on 1". Update the `usage` function's text to match. Verify: `shellcheck --shell=bash packages/session-relink.sh` reports nothing.
- [x] 1.4 Update `packages/session-relink-test.sh`:
  - Remove cases (i), (j), (k), (l), (l2), (l3), (m), (m2), (m3), (m4), (q) and the first (t) (the `realpath` shim), and the GNU `realpath` check near the top with the sentence about it in the header. In (p2), drop the `files.json` line and `--state files.json`.
  - Change (n) to expect `printed "stale .claude/settings.json"` and (p) to expect `printed "missing .claude/settings.json"`.
  - Add to (r): `relink --state files.json .claude/settings.json "$new"` exits 2.
  - Add (u), the property #78 depends on, that a refused file doesn't stop the rest: a stale `.claude/settings.json` in a `chmod a-w` `.claude`, then `relink .claude/settings.json "$new" .pre-commit-config.yaml "$new"`. Expect exit 0, `.claude/settings.json` still pointing at `$old`, and `.pre-commit-config.yaml` pointing at `$new`. Restore the mode before the checks, and skip the case as root, as (d) does.
  - Add (u2): the same with the arguments in the other order, same expectations.
  - Add (v): `--check-only --print` over four paths in one call: a missing `a.json`, a stale link `b.json`, a current link `c.json`, a regular file `d.json`. Expect exit 0 and output exactly `missing a.json` then `stale b.json` on two lines.
  - Add (v2): relink mode with `--print` where the create is denied: `.claude` empty and `chmod a-w`, `relink --print .claude/settings.json "$new"`. Expect exit 0, output `missing .claude/settings.json`, and no `.claude/settings.json` afterwards. Skip as root.
  - Every new case ends with `done_case`.

  Verify: `devenv shell --quiet -- bash packages/session-relink-test.sh packages/session-relink.sh` ends with `0 failed`. Then check the tests bite: temporarily add `break` after the first `stale+=("$f")` in the relink path and confirm (u) fails; temporarily swap `ln -s -- "$want" "$tmp"` plus the `mv` for `ln -sfn -- "$want" "$f"` and confirm (d) fails. Undo both.
- [x] 1.5 In `packages/session-relink.nix`, remove `jq` from `nativeBuildInputs` and from `runtimeInputs`, and reword the header comment: the script is run by the `coldlogic:session-files` task and the stale notice in a Claude Code session. Verify: `devenv shell --quiet -- devenv build shell` succeeds, which runs the tests in the Nix build.

## 2. Wire it into `devenv.nix`

- [x] 2.1 Replace the `protectedFiles` binding (devenv.nix:50-54) with two sets (decision 3):

  ```nix
  # The generated files devenv links (not its copy or seed modes). The
  # notice compares all of them.
  generatedLinks = lib.filterAttrs (_: file: (file.copyMode or "symlink") == "symlink") config.files;
  # The ones a session links itself: all but the settings, which a session
  # never creates, replaces or removes. Only a terminal shell refreshes it.
  sessionLinks = removeAttrs generatedLinks [ config.claude.code.settingsPath ];
  ```

  and make `sessionRelink` take the set as a second argument (`sessionRelink = opts: links: ...`) and build its pairs from it, with `--` before them so a name can't be read as an option: `opts`, then `--`, then for each name in `links` the name and `"${file.file}"`, all through `lib.escapeShellArgs`. Update its comment: exits 1 when nothing is stale, 0 when something is, anything else on an error. The settings file is keyed in `config.files` by exactly `config.claude.code.settingsPath` (devenv.nix:344), so `removeAttrs` with that name drops it. Invariant: the settings path is never an argument of a relink-mode call, so a session can't create, rename over or sweep beside `.claude/settings.json` (#94, mechanism (b)). Verify: `rg -n protectedFiles devenv.nix` finds nothing; 3.2 checks the generated script.
- [x] 2.2 Delete `sessionStatus` and set both statuses to one shared string (decision 1):

  ```nix
  skipInSession = ''
    [ -n "''${CLAUDECODE:-}" ]
  '';
  ```

  `tasks."devenv:files:cleanup".status = skipInSession;` and `tasks."devenv:files".status = skipInSession;`. The test must be the script's last command: a status that exits 0 skips the task, 1 runs it. Invariant: in a session neither task can run, so devenv's `ln -sf` and cleanup's `rm` never reach a generated link (#68, #94). Nothing but `CLAUDECODE` may decide it: no call to the relink script, no `lib.mkIf`. Verify in 3.1.
- [x] 2.3 Add the session's linking task (decision 3), placed after the two statuses:

  ```nix
  tasks."coldlogic:session-files" = {
    exec = ''
      [ -n "''${CLAUDECODE:-}" ] || exit 0
      cd "$DEVENV_ROOT" || exit 0
      ${sessionRelink [ ] sessionLinks} >/dev/null 2>&1 || true
      exit 0
    '';
    after = [ "devenv:files:cleanup" ];
    before = [ "devenv:files" ];
  };
  ```

  Invariants: it is the only relink-mode call in `devenv.nix`, and it is given `sessionLinks`, never `generatedLinks`, so it can't touch the settings link; it writes generated paths only through the relink script, never with `ln -sf`, `rm` or `mv` of its own; and it exits 0 whatever happens, because `devenv:files` depends on it and a failure would skip every later task as a failed dependency (#37). Task scripts run under `set -e`, so keep the `|| exit 0` and `|| true`. Verify in 3.2.
- [x] 2.4 Rewrite `coldlogic:generated-files-stale`'s exec (decisions 5 and 6). Drop the `lib.mkIf (protectedFiles != [ ])` around the task. Keep the session test, the `cd`, `after = [ "devenv:files" ]`, `before = [ "devenv:enterShell" ]` and the final `exit 0`. Capture the output of `sessionRelink [ "--check-only" "--print" ] generatedLinks` as today (only when it exits 0 with output). It is given `generatedLinks`, so the settings link is compared and reported; `--check-only` neither relinks nor sweeps, so this doesn't write beside it. Read it line by line: a line starting `missing ` adds the rest to `missing`, one starting `stale ` adds the rest to `stale`, each space-separated. Build `what` as `missing: <list>`, `out of date: <list>`, or both joined with `; `, leaving out an empty group. Print one line to stderr, in one `echo`:

  `coldlogic: this Claude Code session can't refresh these generated files ($what). Enter the shell once from a terminal, outside a Claude Code session, with: devenv shell. Then restart every Claude Code session open in this checkout, this one included, since a running session can undo the refresh. If a terminal shell doesn't fix them, its evaluation may be stale: run devenv shell --refresh-eval-cache there.`

  In the Nix string, write each shell `${` as `''${`. Invariant: the task only compares (`--check-only`), and never fails. Verify in 3.3.
- [x] 2.5 Rewrite the comment block above the statuses (devenv.nix:501-534) to say what is now true: in a session devenv's two file tasks never run, because `devenv:files` replaces a link with `ln -sf`, which unlinks first, and the sandbox lets the unlink through while denying the create (#68), and because cleanup unlinks; a check used to decide when they were safe, and #94 showed a link could still vanish; the session links the files itself, atomically, one at a time, so one refused file doesn't stop the rest (#78); it never writes the settings link, which only a terminal shell refreshes, in case a settings file changing under a running session is what makes Claude Code remove it (#94); the state file is left for the next terminal shell, whose cleanup removes any orphans. Remove the text about spellings, `--state` and "the sandbox, not a guess, decides whether devenv:files runs". Verify: `rg -n -e sessionStatus -e 'check-only.*state' -e 'spelling' devenv.nix` finds nothing.
- [x] 2.6 Run `devenv shell --quiet -- nixfmt devenv.nix packages/session-relink.nix`, then verify `devenv shell --quiet -- nixfmt --check devenv.nix packages/session-relink.nix` passes.

## 3. Check the generated scripts

No test runs the tasks, so these checks are done by hand, in this worktree's own shell, which uses this `devenv.nix`. Find each script with `devenv shell --quiet -- printenv DEVENV_TASK_FILE`, then `jq` on that file for the task's `status` or `command` path, then read it.

- [x] 3.1 Read both generated status scripts (`devenv:files` and `devenv:files:cleanup`). Verify each is only the `CLAUDECODE` test. Run each with `CLAUDECODE=1` and confirm exit 0, and with `CLAUDECODE` unset (`env -u CLAUDECODE <script>`) and confirm exit 1.
- [x] 3.2 Read the generated `coldlogic:session-files` script. Verify it passes `--`, then `.mcp.json` and `.pre-commit-config.yaml` with the same store paths `devenv:files`' own generated script uses, and that the string `settings.json` appears nowhere in it. Then read the generated `coldlogic:generated-files-stale` script and verify its call has `--check-only --print` and does include the absolute settings path. Then copy the session-files script to `$TMPDIR`, replace the `coldlogic-session-relink` path in the copy with `false`, then with a path that doesn't exist, and confirm the copy exits 0 both times with `CLAUDECODE=1` and `DEVENV_ROOT` set to this worktree. Also confirm it exits 0 with `DEVENV_ROOT=/nonexistent`.
- [x] 3.3 In a session, run `devenv shell --quiet -- true` in this worktree. Verify: `devenv:files` and `devenv:files:cleanup` are marked `(cached)`; `coldlogic:session-files` succeeds; `readlink .pre-commit-config.yaml` and `readlink .mcp.json` print store paths; `devenv: git-hooks config is missing` is no longer printed; `ls -la .claude` shows the same entries and the same `settings.json` target (or absence) as before the run, with no `.settings.json.coldlogic-relink.*`; and when `.claude/settings.json` is missing or stale, the notice names it under `missing:` or `out of date:` and contains `restart every Claude Code session open in this checkout, this one included`. If `devenv:git-hooks:install` still fails for another reason (#67's `core.hooksPath` write), note it in the PR and leave it: that is #93 group 2.
- [x] 3.4 Run `devenv shell --quiet -- openspec validate protected-links-in-session --strict` and verify it reports the change valid.

## 4. Gate

- [x] 4.1 Run `devenv shell --quiet -- scripts/check.sh` and verify it ends with `check: all passed`.

## Review fixes

From `/code-review high` on `ce047ec`.

- [x] R.1 A real file or directory where a link belongs was skipped silently. `packages/session-relink.sh` now records it as `conflict <path>` (never touched, exit 0); tests (f), (p), (p2) and (v) expect it, and the new (f2) covers a directory. The notice lists it as `not links, move them aside first:`. The spec scenario "A real file in place of a link" and design decision 5 say so.
- [x] R.2 The notice dropped lines of an unknown kind and joined paths with bare spaces. Each path is now shell-quoted with `printf %q`, and an unknown line is listed under `other:`, so the notice still prints. Checked by feeding the generated script's parsing lines a path with a space and an unknown kind, and by running the generated script against a root with a real `.mcp.json`.
- [x] R.3 The scenario "The recorded state names a current file differently" described the removed `--state` check. It is now "An orphan in the recorded state", in both spec copies and the REMOVED Migration note; the main spec's Purpose covers every generated link and #94.
- [x] R.4 The two statuses, `coldlogic:session-files` and the notice are guarded with `lib.mkIf` on there being files, so a module with no files gets no partial task. This doesn't decide whether a task runs in a session: that is still only the `CLAUDECODE` test (2.2). Not exercised, since this module always generates the settings file.
- [x] R.5 Copy-mode and seed-mode files: none exist in the module, the profiles or the fixtures. Noted in design.md's Risks; no code change.

## 5. Verification (manual, Derek, after merge)

- [ ] 5.1 In the main checkout, on the new module: run `devenv shell` from a terminal, then restart every Claude Code session open there, as the notice says. With at least two sessions open again, watch `ls -la .claude/settings.json` for two minutes while the sessions run `devenv shell --quiet -- true`. If the link survives, #94 is fixed. If it still vanishes, no shell of ours did it, since a session no longer runs devenv's link step or writes the settings link: Claude Code removes it. Record that on #94 and #68 with the times, and whether a session that was not restarted was open.

## Workflow follow-up

- Archive the change on the feature branch as the last commit before the PR merges.
