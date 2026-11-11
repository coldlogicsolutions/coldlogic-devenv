# Tasks

## 1. The relink script and its test

- [x] 1.1 Write `packages/session-relink.sh` (design.md, decisions 1-4): arguments `[--state <files.json>] <path> <target> ...`, relative to the current directory. For each pair that is missing or a stale link, and doesn't resolve to a directory: remove stray `.<base>.coldlogic-relink.*` links into `/nix/store`, `mkdir -p` the parent, `ln -s` the target to `.<base>.coldlogic-relink.$$`, `mv -f` it over the path, and on any failure `rm -f` the temporary link and mark the path stale. A path that exists and isn't a link is left alone. With `--state`, also mark a skip when a recorded entry differs from a path's current name but resolves to the same `$PWD/…` path. Exit 0 if anything is stale or a skip is marked, else 1. Verify that `shellcheck packages/session-relink.sh` reports nothing.
- [x] 1.2 Write `packages/session-relink-test.sh`. It takes the script's path, works in a fresh `mktemp -d`, needs no sandbox or session, and asserts each case: (a) stale link in a writable dir is relinked, exit 1, no temporary link left; (b) missing link is created, exit 1; (c) current link is untouched, exit 1; (d) stale link in a `chmod a-w` dir keeps its old target, exit 0, no temporary link; (e) with a `mv` shim on `PATH` that exits 1, the stale link keeps its old target, exit 0, and the temporary link is gone; (f) a regular file is untouched, exit 1; (g) a link to a directory is untouched, exit 0; (h) a stray `.<base>.coldlogic-relink.123` link is removed; (i) `--state` with `.claude/settings.json` recorded while the current name is `$PWD/.claude/settings.json` gives exit 0 and the link survives; (j) `--state` with matching spellings gives exit 1. Restore permissions in a trap so the temp dir can be removed. Verify that `bash packages/session-relink-test.sh packages/session-relink.sh` passes, and that it fails when 1.1's `ln -s … && mv -f` is temporarily replaced with `ln -sfn` (case d or e must fail).
- [x] 1.3 Write `packages/session-relink.nix`: a `writeShellApplication` named `coldlogic-session-relink` with `coreutils` and `jq` in `runtimeInputs`, whose build runs the test against the raw script first, as `packages/claude-guard.nix` does, with a header comment saying so. Verify that `nix build --impure --expr '(import ./packages/session-relink.nix { pkgs = import <nixpkgs> {}; })'`, or the devenv shell that uses it, builds and runs the tests.

## 2. Wire it into devenv.nix

- [x] 2.1 In `devenv.nix`, import `packages/session-relink.nix` beside `claude-guard`. Replace the body of `sessionCannotRelink` with the `CLAUDECODE` check, `cd "$DEVENV_ROOT"`, and a call to the script with each protected file and its store path. Keep `tasks."devenv:files".status = sessionCannotRelink`. Update the comment above it to say the relink is atomic and why (#68: `ln -sf` unlinks first, and the sandbox lets the unlink through). Verify that `rg -n 'ln -sfn' devenv.nix` finds nothing.
- [x] 2.2 Give `tasks."devenv:files:cleanup".status` the same call plus `--state "$DEVENV_STATE/files.json"`. Before writing it, check the state path against devenv's cleanup script (from `jq -r '.[] | select(.name=="devenv:files:cleanup") | .command' "$DEVENV_TASK_FILE"`) and use the variable or option that yields the same path. Add a comment for decision 4. Verify by reading the generated status script (`jq -r '... .status' "$DEVENV_TASK_FILE"`, then `cat` that path) and checking that it passes `--state` with the path the cleanup script reads.
- [x] 2.3 In `coldlogic:generated-files-stale`, keep the notice and append: `If a terminal shell doesn't fix them, its evaluation may be stale: run devenv shell --refresh-eval-cache there.` Verify by reading the generated task script.
- [x] 2.4 Run `nixfmt --check devenv.nix packages/session-relink.nix` and verify it passes.
- [x] 2.5 Run `devenv shell --quiet -- true` in this worktree, outside a session if possible, and verify `devenv:files` and `devenv:files:cleanup` still succeed and `.claude/settings.json` points at the current store path. There is no `scripts/check.sh` yet (#63), so 1.2, 2.4 and this step are the checks.
- [x] 2.6 Run `devenv shell --quiet -- openspec validate settings-relink-atomic --strict` and verify it reports the change valid.

## 2a. Review fixes

- [x] 2a.1 `--state` fails closed: a state file that isn't exactly one `{"managedFiles": [<string>...]}` (malformed, wrong shape, empty, several documents) marks a skip. Tests (k), (l).
- [x] 2a.2 The stray-temporary sweep removes only links whose PID suffix isn't this run's and whose process `kill -0` reports as gone ("No such process"; EPERM keeps it). On failure, only a temporary link this run made is removed. Tests (h), (h2).
- [x] 2a.3 Recorded entries and current names are compared as `realpath -ms` absolute paths (`$PWD/` prefixed as cleanup does; no link is resolved). Tests (m) for `.claude//settings.json`, `x/../.claude/settings.json` and `./.claude/./settings.json`, and (m2).
- [x] 2a.4 The test's temporary-link check searches the whole case directory recursively and runs at the end of every case.
- [x] 2a.5 `--check-only` (no relink, no sweep) and `--print` (stale names). `coldlogic:generated-files-stale` uses `--check-only --print`. Tests (n)–(q).
- [x] 2a.6 `devenv:files:cleanup`'s status is `--check-only --state`; only `devenv:files`' status relinks (design.md, decision 5). Verify in the generated tasks.json that cleanup is `before` `devenv:files` and `devenv:files` is `after` cleanup.

## 2b. Review fixes, round 2

- [x] 2b.1 Both statuses run their task only on the script's explicit exit 1; any other exit, or a failed `cd`, skips (exit 0). Outside a session they exit 1. The script exits 3 when a command fails (ERR trap, explicit exits in `if` conditions). Tests (t). The wrappers in `devenv.nix` aren't built into a test: check them by running the generated status scripts with the binary stubbed to exit 0, 1, 2, 3 and 127.
- [x] 2b.2 A real file is never stale, in any mode. Tests (p), (p2).
- [x] 2b.3 In relink mode the sweep runs for every protected path, before the current-link check. Test (h3).
- [x] 2b.4 Recorded entries are read both as `$PWD/<entry>` and, when they start with `/`, as absolute paths. Tests (m2), now a skip, (m3) and (m4).
- [x] 2b.5 One helper, `respells`, holds the normalisation and the exact-match guard.
- [x] 2b.6 A leftover temporary link is removed only when its process is gone and the link is more than a minute old (`find -mmin +1`; findutils is a runtime input). Tests (h), (h1).
- [x] 2b.7 The notice requirement's "Tested by" names the script test for the comparison and says the notice text is untested.

## 3. Verification (manual, Derek, after merge)

- [ ] 3.1 In a Claude Code session in a checkout on the new module, make `.claude/settings.json` stale from a terminal: `ln -sfn <an older settings store path> .claude/settings.json`, or enter a terminal shell on an older lock. Restart the session so it starts from that link. Then, in the session, run `devenv shell --quiet -- true`. Verify that `readlink .claude/settings.json` still shows the old store path after that call and after the session's next two tool calls, that no `.settings.json.coldlogic-relink.*` file is left in `.claude/`, and that the notice names `--refresh-eval-cache`. Note on #68 whether the sandbox denied the create, the rename, or neither, and whether Claude Code reverted anything.

## Workflow follow-up

- Archive the change on the feature branch as the last commit before the PR merges.
