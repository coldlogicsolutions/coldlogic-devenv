# Tasks

Run every command through `devenv shell --quiet -- <cmd>`. Scratch files go under `$TMPDIR`, never in the repository. The only files this change edits are `devenv.nix`, `scripts/check.sh`, `.github/workflows/check.yaml` (a comment) and `README.md`.

The command the tasks call "the probe", run in a fixture directory after copying the module's lock into it (`cp devenv.lock tests/fixtures/<name>`, as `fixture_builds` does; the copy is gitignored):

```bash
devenv --profile ci shell --quiet -- bash -c '"$DEVENV_PROFILE/bin/openspec" --version'
```

It runs `openspec` from the shell's own packages. Never judge by plain `openspec` or `command -v openspec` inside a fixture's shell: the shell inherits the caller's `PATH`, which already has one (design.md, decision 3).

## 1. openspec in the ci profile

- [x] 1.1 In `devenv.nix`, between `cachix.pull = [ "coldlogic" ];` (line 146) and `profiles.developer.module =` (line 148), add `profiles.ci.module` exactly as in design.md, decision 1: a two-line comment saying a project's gate runs `openspec validate` in CI so `ci` gets openspec and nothing else of the module's, then a module `{ pkgs, ... }:` whose only setting is `packages = [ pkgs.openspec ];`. Set no `extends`. Leave `openspec` in the `developer` packages (line 601) and add nothing at the top level: the invariant is that `build` and unprofiled shells get none of the module's tooling. Verify: `nixfmt --check devenv.nix` exits 0.
- [x] 1.2 Confirm the definitions merge in the real fixtures, which planning could only run on stand-ins. In `tests/fixtures/rust-lib` and then `tests/fixtures/rust-worker`, with the lock copied in, run `devenv --profile ci shell --quiet -- bash -c 'ls "$DEVENV_PROFILE/bin"'`. Verify the listing has `openspec` in both, `gcc` in both (from `rust-lib`'s own `ci` module), and `topcoat` in `rust-worker` (from its own `ci` module), so the new module added to the others and replaced none. If `openspec` is missing or the shell fails to evaluate, stop and report with the error; don't move the package elsewhere.
- [x] 1.3 Confirm `build` got nothing. In `tests/fixtures/rust-lib`, run `devenv --profile build shell --quiet -- bash -c 'test ! -e "$DEVENV_PROFILE/bin/openspec"'`. Verify it exits 0. (This builds the fixture's `build` shell, which the gate doesn't; it is a subset of the `ci` shell.)
- [x] 1.4 In `README.md`, in the `devenv.nix` row of "What's here" (line 172), put the `ci` part before the existing text, so the cell starts: `` `ci`: `openspec`, which a project's gate runs there (a project with no language profile gets a `ci` profile holding it alone); `developer`: `git`, `openspec`, `gh-app`, ... `` with the rest of the cell unchanged. Verify the row matches `devenv.nix`: `openspec` in both profiles, nothing else of the module's in `ci`.

## 2. The gate's check

- [x] 2.1 In `scripts/check.sh`, add the function `fixture_ci_has_openspec` after `fixture_builds` (after line 112), with its comment and its `# shellcheck disable=SC2016` directive, exactly as in design.md, decision 3. In the fixture loop (lines 139-144), add `step "ci openspec: ${fixture##*/}" fixture_ci_has_openspec "$fixture"` after the inner `for profile` loop's `done` and before the outer `done`. Use `step`, not `with_tools`. Keep it bash 3.2 compatible. Verify: `shellcheck --shell=bash scripts/check.sh` exits 0, with the directive in place (without it SC2016 fails the gate's shellcheck step).
- [x] 2.2 Run the probe in each fixture, from inside the developer shell (that is where an inherited `openspec` is on `PATH`). Verify each prints a version and exits 0. If the probe fails in a real fixture for a reason other than `openspec` being absent (for example `DEVENV_PROFILE` unset), switch the function to the fallback in design.md, decision 3 (`devenv --profile ci shell --quiet --clean -- openspec --version`, no shellcheck directive), rerun this task with it, and say so in the PR.
- [x] 2.3 Prove the check can fail, from a Claude Code session. Temporarily delete the `profiles.ci.module` block added in 1.1, then run the gate: `devenv shell --quiet -- scripts/check.sh`. Verify the summary shows `FAIL  ci openspec: rust-lib` and `FAIL  ci openspec: rust-worker`, every other check passed (the four `build:` fixture steps included), and the exit code is 1. This is the threat the check exists for: it must fail although the gate's own `PATH` has `openspec`. If either step passes, the check is vacuous: stop and report. Then restore the block and verify `git diff devenv.nix` shows only the addition from 1.1.
- [x] 2.4 Update the gate's descriptions. In `README.md`, the `scripts/check.sh` row (line 188): after "and of each fixture's `ci` and `developer` shells", add that it then checks each fixture's `ci` shell has `openspec` (`ci openspec: <fixture>`), running it from the shell's own packages because the gate's `PATH` already has one. In `.github/workflows/check.yaml`, the header comment (lines 1-4): add the same check to the list. Verify both read correctly against `scripts/check.sh`, and that the workflow's steps are unchanged (`git diff .github` shows comment lines only).

## 3. Verification

- [x] 3.1 Run `openspec validate ci-profile-openspec --strict` and verify it passes. Then check the length of the modified toolchain-profiles requirement, which `--strict` only enforces once it is archived into the main spec: `awk 'NR>=6 && NR<=8 { n += length($0) + 1 } END { print n - 1 }' openspec/changes/ci-profile-openspec/specs/toolchain-profiles/spec.md` prints 495 (the description and its `Tested by` line; the limit is 500). If the delta was edited and it prints more than 500, shorten the `Tested by` line, not the requirement's sentences.
- [x] 3.2 Run the gate from a Claude Code session: `devenv shell --quiet -- scripts/check.sh`. Verify the summary lists `ci openspec: rust-lib` and `ci openspec: rust-worker` as passed, each printed a version, every other check passed, and the exit code is 0. If the two new steps fail in the session but task 2.2's probe passed, the shell entry needs something the sandbox denies: stop and report with the output, since the gate must give the same result in a session, a terminal and CI.

## Workflow follow-up

- On the PR, confirm the `check` job's log shows both `ci openspec` steps passing on Linux.
- After the merge, confirm the cache job builds and pushes both fixtures' `ci` shells and that coldlogic-audio-common's update PR, then its main, pass.
- The main session files the follow-up issue for `nixfmt` and `shellcheck` in `ci`.
- Archive the change once it is merged, and confirm `openspec validate --all --strict` still passes with the toolchain-profiles requirement in the main spec.
